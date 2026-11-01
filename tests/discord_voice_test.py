#!/usr/bin/env python3
"""Runs the voice bridge against a stand-in for the Discord app."""
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

bridge = Path(__file__).resolve().parent.parent / "widgets/discord-voice/bridge.py"
PORT = 5687


def voice(uid, name, muted=False):
    return {"nick": name, "user": {"id": uid, "username": name, "avatar": None},
            "voice_state": {"self_mute": muted, "self_deaf": False}}


class FakeDiscord:
    """Answers RPC calls, and pushes events once the bridge has subscribed."""

    def __init__(self, path, approve=True):
        self.approve = approve
        self.prompts = 0
        self.server = socket.socket(socket.AF_UNIX)
        self.server.bind(str(path))
        self.server.listen(1)
        self.subscribed = threading.Event()
        self.conn = None
        threading.Thread(target=self.run, daemon=True).start()

    def send(self, payload, op=1):
        body = json.dumps(payload).encode()
        self.conn.sendall(struct.pack("<II", op, len(body)) + body)

    def event(self, name, data):
        self.send({"cmd": "DISPATCH", "evt": name, "data": data})

    def read(self):
        header = self.conn.recv(8, socket.MSG_WAITALL)
        if len(header) < 8:
            return None
        return json.loads(self.conn.recv(struct.unpack("<II", header)[1], socket.MSG_WAITALL))

    def run(self):
        self.conn, _ = self.server.accept()
        self.read()
        self.send({"cmd": "DISPATCH", "evt": "READY", "data": {"v": 1}})
        while (message := self.read()) is not None:
            data = {}
            if message["cmd"] == "AUTHORIZE":
                self.prompts += 1
                # The real client refuses a redirect_uri in this flow.
                if not self.approve or "redirect_uri" in message["args"]:
                    self.send({"cmd": "AUTHORIZE", "nonce": message["nonce"], "evt": "ERROR",
                               "data": {"code": 5000, "message": "OAuth2 Error"}})
                    continue
                data = {"code": "abc"}
            if message["cmd"] == "GET_SELECTED_VOICE_CHANNEL":
                data = {"id": "1"}
            elif message["cmd"] == "GET_CHANNEL":
                data = {"id": "1", "guild_id": "9", "name": "lobby", "voice_states": [voice("100", "Ada")]}
            elif message["cmd"] == "GET_GUILD":
                data = {"name": "The Server"}
            self.send({"cmd": message["cmd"], "nonce": message["nonce"], "evt": None, "data": data})
            if message["cmd"] == "SUBSCRIBE" and message.get("evt") == "SPEAKING_STOP":
                self.subscribed.set()


def state():
    with urllib.request.urlopen(f"http://127.0.0.1:{PORT}/state", timeout=2) as response:
        return json.load(response)


def wait_for(condition):
    deadline = time.time() + 5
    while time.time() < deadline:
        try:
            current = state()
            if condition(current):
                return current
        except OSError:
            pass
        time.sleep(0.05)
    raise SystemExit(f"timed out, last state: {current if 'current' in locals() else 'none'}")


class Tokens(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        body = json.dumps({"access_token": "a", "refresh_token": "r", "expires_in": 604800}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def sign_in(approve):
    """Starts with no token, as a first run does."""
    tokens = HTTPServer(("127.0.0.1", 0), Tokens)
    threading.Thread(target=tokens.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder)
        (root / "discord-voice-widget").mkdir()
        config = root / "discord-voice-widget/config.json"
        config.write_text(json.dumps({"client_id": "1", "client_secret": "s"}))
        discord = FakeDiscord(root / "discord-ipc-0", approve)
        env = {**os.environ, "XDG_CONFIG_HOME": folder, "XDG_RUNTIME_DIR": folder,
               "DISCORD_VOICE_PORT": str(PORT),
               "DISCORD_VOICE_TOKEN_URL": f"http://127.0.0.1:{tokens.server_port}/"}
        process = subprocess.Popen([sys.executable, "-I", str(bridge)], env=env, stdout=subprocess.DEVNULL)
        try:
            if approve:
                wait_for(lambda s: s["status"] == "in-call")
                assert json.loads(config.read_text())["access_token"] == "a"
            else:
                wait_for(lambda s: s["status"] == "auth-error")
                time.sleep(6)
                assert discord.prompts == 1, f"prompted {discord.prompts} times"
        finally:
            process.terminate()
            process.wait()
            tokens.shutdown()


def main():
    sign_in(approve=True)
    sign_in(approve=False)
    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder)
        (root / "discord-voice-widget").mkdir()
        (root / "discord-voice-widget/config.json").write_text(json.dumps({
            "client_id": "1", "client_secret": "s", "access_token": "t", "expires_at": time.time() + 86400,
        }))
        discord = FakeDiscord(root / "discord-ipc-0")
        env = {**os.environ, "XDG_CONFIG_HOME": folder, "XDG_RUNTIME_DIR": folder, "DISCORD_VOICE_PORT": str(PORT)}
        process = subprocess.Popen([sys.executable, "-I", str(bridge)], env=env)
        try:
            found = wait_for(lambda s: s["status"] == "in-call")
            assert found["channel"] == "lobby" and found["guild"] == "The Server", found
            assert [user["name"] for user in found["users"]] == ["Ada"], found
            assert discord.subscribed.wait(5)

            discord.event("VOICE_STATE_CREATE", voice("200", "Grace", muted=True))
            found = wait_for(lambda s: len(s["users"]) == 2)
            assert found["users"][1]["muted"] and "embed/avatars" in found["users"][1]["avatar"], found

            discord.event("SPEAKING_START", {"user_id": "100"})
            wait_for(lambda s: s["users"][0]["speaking"])
            discord.event("VOICE_STATE_UPDATE", voice("100", "Ada"))
            time.sleep(0.2)
            assert state()["users"][0]["speaking"], "an update must not clear speaking"
            discord.event("SPEAKING_STOP", {"user_id": "100"})
            wait_for(lambda s: not s["users"][0]["speaking"])

            discord.event("VOICE_STATE_DELETE", voice("200", "Grace"))
            wait_for(lambda s: len(s["users"]) == 1)

            discord.event("VOICE_CHANNEL_SELECT", {"channel_id": None, "guild_id": None})
            found = wait_for(lambda s: s["status"] == "idle")
            assert found["users"] == [], found

            discord.conn.shutdown(socket.SHUT_RDWR)
            wait_for(lambda s: s["status"] == "offline")
        finally:
            process.terminate()
            process.wait()


if __name__ == "__main__":
    main()
