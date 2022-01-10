import threading
import time
import uuid

import docker
import requests
from flask import Flask, request
from werkzeug.serving import make_server

app = Flask(__name__)
with open("static/notifs.html", "r") as f:
    notif_template = f.read()
base_cookies = {
    "a": "ffd506ce-d217-4fca-b505-792edc6b7297",
    "b": "2d0163b8-da67-42fc-8a3a-9e57f66eacaa"
}
flask_port = 7652


@app.route("/msg/others/")
def notifications_page():
    result = notif_template.replace("{{username}}", f"a={request.cookies.get('a')};b={request.cookies.get('b')}")
    return result


class ExportContainer:
    def __init__(self):
        self.client = docker.from_env()
        self.container = None

    def start(self) -> None:
        bypass_url = f"http://host.docker.internal:{flask_port}"
        self.container = self.client.containers.run(
            "deerspangle/furaffinity-api",
            detach=True,
            ports={
                9292: 9292
            },
            environment={
                "FA_COOKIE": f"a\\={base_cookies['a']}\\;b\\={base_cookies['b']}",
                "CF_BYPASS": bypass_url,
                "CF_BYPASS_SFW": bypass_url
            }
        )
        print("Started container")
        while True:
            try:
                requests.get("http://localhost:9292")
                return
            except Exception:
                print("API isn't running yet")
                time.sleep(1)

    def stop(self) -> None:
        if self.container is None:
            return
        self.container.kill()
        self.container.remove(force=True)

    def __enter__(self):
        self.start()

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.stop()


def check_notifs():
    a = uuid.uuid4()
    b = uuid.uuid4()
    cookie_str = f"a={a};b={b}"
    try:
        resp = requests.get("http://localhost:9292/notifications/others.json", headers={"FA_COOKIE": cookie_str})
        data = resp.json()
    except Exception as e:
        print(f"That request failed: {e}")
        return
    current_username = data["current_user"]["name"]
    if current_username == cookie_str:
        print("All good")
    else:
        print(f"Darn. It gave:")
        print(current_username)
        print("I wanted: ")
        print(cookie_str)
        raise ValueError


def check_mock():
    a = uuid.uuid4()
    b = uuid.uuid4()
    cookie_str = f"a={a};b={b}"
    try:
        resp = requests.get(
            f"http://127.0.0.1:{flask_port}/msg/others/",
            cookies={
                "a": str(a),
                "b": str(b)
            }
        )
        data = resp.content
    except Exception as e:
        print(f"That request failed: {e}")
        return
    if cookie_str in data.decode():
        print("Mock is good")
    else:
        print(f"Darn. Mock is missing the cookie")
        raise ValueError


class ServerThread(threading.Thread):

    def __init__(self):
        threading.Thread.__init__(self)
        self.server = make_server('127.0.0.1', flask_port, app)
        self.ctx = app.app_context()
        self.ctx.push()

    def run(self):
        self.server.serve_forever()

    def shutdown(self):
        self.server.shutdown()

    def __enter__(self):
        self.start()

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.shutdown()


if __name__ == '__main__':
    with ServerThread():
        with ExportContainer():
            count = 0
            while True:
                print(f"Checking: {count}")
                check_mock()
                check_notifs()
                count += 1