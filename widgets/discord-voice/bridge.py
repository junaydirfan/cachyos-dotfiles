#!/usr/bin/env python3
"""Serves the Discord voice channel you're in as JSON for the desktop widget.

Talks to the Discord app over its local RPC socket and answers on 127.0.0.1 only.
Credentials stay in ~/.config/discord-voice-widget/config.json, outside the repo.
"""
import json
import os
import queue
import select
import socket
import struct
import threading
import time
import urllib.error
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
# The widget's request stays open until something changes, so updates are instant.
LONG_POLL_SECONDS = 20
OP_HANDSHAKE, OP_FRAME, OP_CLOSE, OP_PING, OP_PONG = range(5)


class Closed(Exception):
    """Discord went away, so start over."""


class AuthFailed(Exception):
    """Sign-in failed. Retrying would only keep popping up Discord's approval prompt."""


class State:
    """What the widget sees. Writes come from the RPC loop, reads from HTTP threads."""

    def __init__(self):
        self.lock = threading.Condition()
        self.version = 0
        self.status = "offline"
        self.channel = ""
        self.guild = ""
        self.link = ""
        self.users = {}
        self.self_id = ""
        self.self_muted = False
        self.self_deafened = False
        self.actions = queue.SimpleQueue()
        self.wake_read, self.wake_write = os.pipe()

    def changed(self):
        self.version += 1
        self.lock.notify_all()

    def set(self, status, channel="", guild="", link=""):
        with self.lock:
            self.status, self.channel, self.guild, self.link = status, channel, guild, link
            self.users = {}
            self.changed()

    def set_self(self, muted, deafened):
        with self.lock:
            self.self_muted, self.self_deafened = bool(muted), bool(deafened)
            self.changed()

    def set_listening(self, uid, **fields):
        with self.lock:
            if uid in self.users:
                self.users[uid].update(fields)
                self.changed()

    def request(self, action):
        self.actions.put(action)
        os.write(self.wake_write, b"x")

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
                "self": uid == self.self_id,
                "volume": int(voice.get("volume", 100)),
                "localMute": bool(voice.get("mute")),
            }
            self.changed()

    def drop_user(self, voice):
        with self.lock:
            self.users.pop((voice.get("user") or {}).get("id"), None)
            self.changed()

    def speaking(self, uid, value):
        with self.lock:
            if uid in self.users:
                self.users[uid]["speaking"] = value
                self.changed()

    def snapshot(self, since=None):
        with self.lock:
            if since == self.version:
                self.lock.wait(LONG_POLL_SECONDS)
            return {
                "version": self.version,
                "status": self.status,
                "channel": self.channel,
                "guild": self.guild,
                "link": self.link,
                "selfMuted": self.self_muted,
                "selfDeafened": self.self_deafened,
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


def sign_in(rpc, config):
    # On this socket redirect_uri is refused, and response_type makes Discord use the
    # app's first registered redirect instead.
    args = {"client_id": config["client_id"], "scopes": SCOPES, "response_type": "code"}
    try:
        code = rpc.call("AUTHORIZE", args)["code"]
        request_token(config, grant_type="authorization_code", code=code, redirect_uri=REDIRECT)
    except urllib.error.HTTPError as error:
        raise AuthFailed(f"token request refused: {error.code} {error.read()[:200]!r}") from error
    except RuntimeError as error:
        raise AuthFailed(str(error)) from error


def forget_token(config):
    config.pop("access_token", None)
    save_config(config)


def authenticate(rpc, config, state):
    if not config.get("access_token"):
        state.set("authorizing")
        sign_in(rpc, config)
    elif time.time() > config.get("expires_at", 0) - 3600:
        try:
            request_token(config, grant_type="refresh_token", refresh_token=config["refresh_token"])
        except urllib.error.HTTPError:
            forget_token(config)
            raise
    try:
        state.self_id = rpc.call("AUTHENTICATE", {"access_token": config["access_token"]})["user"]["id"]
    except RuntimeError:
        # Only a rejected token should bring Discord's approval prompt back.
        forget_token(config)
        raise


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
        elif event == "VOICE_SETTINGS_UPDATE":
            self.state.set_self(data.get("mute"), data.get("deaf"))

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
        place = channel.get("guild_id") or "@me"
        link = f"discord://-/channels/{place}/{channel.get('id')}"
        self.state.set("in-call", channel.get("name") or "Direct call", guild, link)
        for voice in channel.get("voice_states") or []:
            self.state.put_user(voice)

    def act(self, action):
        name, uid = action.get("action"), action.get("user_id")
        state = self.state
        if name == "toggle-mute":
            self.rpc.call("SET_VOICE_SETTINGS", {"mute": not state.self_muted})
        elif name == "toggle-deafen":
            self.rpc.call("SET_VOICE_SETTINGS", {"deaf": not state.self_deafened})
        elif name == "leave":
            self.rpc.call("SELECT_VOICE_CHANNEL", {"channel_id": None})
        elif name == "user-mute" and uid:
            mute = bool(action.get("mute"))
            self.rpc.call("SET_USER_VOICE_SETTINGS", {"user_id": uid, "mute": mute})
            state.set_listening(uid, localMute=mute)
        elif name == "user-volume" and uid:
            volume = max(0, min(200, int(action.get("volume", 100))))
            self.rpc.call("SET_USER_VOICE_SETTINGS", {"user_id": uid, "volume": volume})
            state.set_listening(uid, volume=volume)

    def run(self):
        self.rpc.call("SUBSCRIBE", {}, "VOICE_CHANNEL_SELECT")
        self.rpc.call("SUBSCRIBE", {}, "VOICE_SETTINGS_UPDATE")
        voice = self.rpc.call("GET_VOICE_SETTINGS")
        self.state.set_self(voice.get("mute"), voice.get("deaf"))
        current = self.rpc.call("GET_SELECTED_VOICE_CHANNEL")
        self.follow(current.get("id"))
        wake = self.state.wake_read
        while True:
            if self.pending is not None:
                channel_id, self.pending = self.pending, None
                self.follow(channel_id or None)
            ready, _, _ = select.select([self.rpc.sock, wake], [], [])
            if wake in ready:
                os.read(wake, 4096)
                while not self.state.actions.empty():
                    try:
                        self.act(self.state.actions.get())
                    except (RuntimeError, ValueError) as error:
                        print(f"action failed: {error}", flush=True)
            if self.rpc.sock in ready:
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
        authenticate(rpc, config, state)
        session.run()
    finally:
        rpc.close()
        if state.status != "auth-error":
            state.set("offline")


class Handler(BaseHTTPRequestHandler):
    state = None

    def allowed(self):
        # Stops a web page reaching this through a rebound domain name.
        return self.headers.get("Host") in (f"127.0.0.1:{PORT}", f"localhost:{PORT}")

    def reply(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if not self.allowed():
            self.reply(403, {})
            return
        query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        since = query.get("since", [None])[0]
        self.reply(200, self.state.snapshot(int(since) if since and since.isdigit() else None))

    def do_POST(self):
        # Browsers can't add this header across sites without permission we never give.
        if not self.allowed() or self.headers.get("X-Voice-Widget") != "1":
            self.reply(403, {})
            return
        try:
            action = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            self.state.request(action)
        except ValueError:
            self.reply(400, {})
            return
        self.reply(200, {})

    def log_message(self, *args):
        pass


def wait_for_new_config():
    """Sign-in is only worth retrying once setup has saved something different."""
    before = CONFIG.stat().st_mtime
    while CONFIG.stat().st_mtime == before:
        time.sleep(RETRY_SECONDS)


def main():
    state = State()
    Handler.state = state
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    while True:
        try:
            run_once(state)
        except AuthFailed as error:
            print(f"sign-in failed: {error}", flush=True)
            state.set("auth-error")
            wait_for_new_config()
        except (Closed, OSError, ValueError, KeyError, RuntimeError) as error:
            print(f"reconnecting: {error!r}", flush=True)
        time.sleep(RETRY_SECONDS)


if __name__ == "__main__":
    main()
