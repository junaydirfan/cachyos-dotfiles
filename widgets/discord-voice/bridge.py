#!/usr/bin/env python3
"""Serves the Discord voice channel you're in as JSON for the desktop widget.

Talks to the Discord app over its local RPC socket and answers on 127.0.0.1 only.
Credentials stay in ~/.config/discord-voice-widget/config.json, outside the repo.
"""
import json
import os
import socket
import struct
import threading
import time
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = int(os.environ.get("DISCORD_VOICE_PORT", "5617"))
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "discord-voice-widget/config.json"
RUNTIME = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
TOKEN_URL = os.environ.get("DISCORD_VOICE_TOKEN_URL", "https://discord.com/api/oauth2/token")
REDIRECT = "http://127.0.0.1"
SCOPES = ["rpc", "identify"]
RETRY_SECONDS = 5
OP_HANDSHAKE, OP_FRAME, OP_CLOSE, OP_PING, OP_PONG = range(5)


class Closed(Exception):
    """Discord went away, so start over."""


class State:
    """What the widget sees. Writes come from the RPC loop, reads from HTTP threads."""

    def __init__(self):
        self.lock = threading.Lock()
        self.status = "offline"
        self.channel = ""
        self.guild = ""
        self.users = {}

    def set(self, status, channel="", guild=""):
        with self.lock:
            self.status, self.channel, self.guild = status, channel, guild
            self.users = {}

    def put_user(self, voice):
        user = voice.get("user") or {}
        uid = user.get("id")
        if not uid:
            return
        flags = voice.get("voice_state") or {}
        with self.lock:
            speaking = self.users.get(uid, {}).get("speaking", False)
            self.users[uid] = {
                "id": uid,
                "name": voice.get("nick") or user.get("global_name") or user.get("username") or "Unknown",
                "avatar": avatar_url(uid, user.get("avatar")),
                "muted": bool(flags.get("self_mute") or flags.get("mute") or flags.get("suppress")),
                "deafened": bool(flags.get("self_deaf") or flags.get("deaf")),
                "speaking": speaking,
            }

    def drop_user(self, voice):
        with self.lock:
            self.users.pop((voice.get("user") or {}).get("id"), None)

    def speaking(self, uid, value):
        with self.lock:
            if uid in self.users:
                self.users[uid]["speaking"] = value

    def snapshot(self):
        with self.lock:
            return {
                "status": self.status,
                "channel": self.channel,
                "guild": self.guild,
                "users": list(self.users.values()),
            }


def avatar_url(uid, avatar):
    if avatar:
        return f"https://cdn.discordapp.com/avatars/{uid}/{avatar}.png?size=64"
    return f"https://cdn.discordapp.com/embed/avatars/{(int(uid) >> 22) % 6}.png"


def load_config():
    try:
        return json.loads(CONFIG.read_text())
    except (OSError, ValueError):
        return None


def save_config(config):
    temporary = CONFIG.with_suffix(".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as file:
        json.dump(config, file)
    temporary.replace(CONFIG)


def request_token(config, **fields):
    body = urllib.parse.urlencode({
        "client_id": config["client_id"],
        "client_secret": config["client_secret"],
        **fields,
    }).encode()
    # Discord's CDN refuses Python's default user agent.
    request = urllib.request.Request(TOKEN_URL, body, {"User-Agent": "discord-voice-widget"})
    with urllib.request.urlopen(request, timeout=15) as response:
        tokens = json.load(response)
    config["access_token"] = tokens["access_token"]
    config["refresh_token"] = tokens["refresh_token"]
    config["expires_at"] = time.time() + tokens["expires_in"]
    save_config(config)


class Rpc:
    def __init__(self, path, on_event):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.connect(str(path))
        self.on_event = on_event

    def close(self):
        self.sock.close()

    def send(self, op, payload):
        body = json.dumps(payload).encode()
        self.sock.sendall(struct.pack("<II", op, len(body)) + body)

    def read_exact(self, size):
        data = b""
        while len(data) < size:
            chunk = self.sock.recv(size - len(data))
            if not chunk:
                raise Closed()
            data += chunk
        return data

    def read(self):
        op, size = struct.unpack("<II", self.read_exact(8))
        payload = json.loads(self.read_exact(size))
        if op == OP_CLOSE:
            raise Closed()
        if op == OP_PING:
            self.send(OP_PONG, payload)
            return None
        return payload

    def wait_ready(self):
        while True:
            message = self.read()
            if message and message.get("evt") == "READY":
                return

    def call(self, command, args=None, evt=None):
        nonce = str(uuid.uuid4())
        message = {"cmd": command, "args": args or {}, "nonce": nonce}
        if evt:
            message["evt"] = evt
        self.send(OP_FRAME, message)
        # Events can arrive before the reply and must not be lost.
        while True:
            reply = self.read()
            if reply is None:
                continue
            if reply.get("nonce") == nonce:
                if reply.get("evt") == "ERROR":
                    raise RuntimeError(reply.get("data", {}).get("message", "RPC error"))
                return reply.get("data") or {}
            self.on_event(reply)

    def listen(self):
        while True:
            message = self.read()
            if message:
                self.on_event(message)


def authenticate(rpc, config):
    if not config.get("access_token"):
        code = rpc.call("AUTHORIZE", {"client_id": config["client_id"], "scopes": SCOPES})["code"]
        request_token(config, grant_type="authorization_code", code=code, redirect_uri=REDIRECT)
    elif time.time() > config.get("expires_at", 0) - 3600:
        request_token(config, grant_type="refresh_token", refresh_token=config["refresh_token"])
    rpc.call("AUTHENTICATE", {"access_token": config["access_token"]})


class Session:
    """Follows the voice channel you're in across one connection to Discord."""

    CHANNEL_EVENTS = ("VOICE_STATE_CREATE", "VOICE_STATE_UPDATE", "VOICE_STATE_DELETE",
                      "SPEAKING_START", "SPEAKING_STOP")

    def __init__(self, state):
        self.state = state
        self.rpc = None
        self.channel_id = None
        self.pending = None

    def on_event(self, message):
        event, data = message.get("evt"), message.get("data") or {}
        if event == "VOICE_CHANNEL_SELECT":
            # Handled in the main loop, as calls can't be made from inside a read.
            self.pending = data.get("channel_id") or ""
        elif event in ("VOICE_STATE_CREATE", "VOICE_STATE_UPDATE"):
            self.state.put_user(data)
        elif event == "VOICE_STATE_DELETE":
            self.state.drop_user(data)
        elif event == "SPEAKING_START":
            self.state.speaking(data.get("user_id"), True)
        elif event == "SPEAKING_STOP":
            self.state.speaking(data.get("user_id"), False)

    def follow(self, channel_id):
        previous, self.channel_id = self.channel_id, channel_id
        if previous:
            for event in self.CHANNEL_EVENTS:
                self.rpc.call("UNSUBSCRIBE", {"channel_id": previous}, event)
        if not channel_id:
            self.state.set("idle")
            return
        channel = self.rpc.call("GET_CHANNEL", {"channel_id": channel_id})
        self.show(channel)
        for event in self.CHANNEL_EVENTS:
            self.rpc.call("SUBSCRIBE", {"channel_id": channel_id}, event)

    def show(self, channel):
        guild = ""
        if channel.get("guild_id"):
            guild = self.rpc.call("GET_GUILD", {"guild_id": channel["guild_id"]}).get("name", "")
        self.state.set("in-call", channel.get("name") or "Direct call", guild)
        for voice in channel.get("voice_states") or []:
            self.state.put_user(voice)

    def run(self):
        self.rpc.call("SUBSCRIBE", {}, "VOICE_CHANNEL_SELECT")
        current = self.rpc.call("GET_SELECTED_VOICE_CHANNEL")
        self.follow(current.get("id"))
        while True:
            if self.pending is not None:
                channel_id, self.pending = self.pending, None
                self.follow(channel_id or None)
            message = self.rpc.read()
            if message:
                self.on_event(message)


def find_socket():
    for number in range(10):
        path = RUNTIME / f"discord-ipc-{number}"
        if path.exists():
            return path
    return None


def run_once(state):
    config = load_config()
    if not config or not config.get("client_id") or not config.get("client_secret"):
        state.set("no-config")
        return
    path = find_socket()
    if path is None:
        state.set("offline")
        return
    session = Session(state)
    rpc = Rpc(path, session.on_event)
    session.rpc = rpc
    try:
        rpc.send(OP_HANDSHAKE, {"v": 1, "client_id": config["client_id"]})
        rpc.wait_ready()
        authenticate(rpc, config)
        session.run()
    finally:
        rpc.close()
        state.set("offline")


class Handler(BaseHTTPRequestHandler):
    state = None

    def do_GET(self):
        body = json.dumps(self.state.snapshot()).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def main():
    state = State()
    Handler.state = state
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    while True:
        try:
            run_once(state)
        except (Closed, OSError, ValueError, KeyError, RuntimeError) as error:
            print(f"reconnecting: {error!r}", flush=True)
            # A rejected token won't recover by itself, so ask Discord again.
            if isinstance(error, RuntimeError):
                config = load_config()
                if config:
                    config.pop("access_token", None)
                    save_config(config)
        time.sleep(RETRY_SECONDS)


if __name__ == "__main__":
    main()
