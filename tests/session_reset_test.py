import importlib.util
import json
from pathlib import Path
import socket
import threading
import unittest
from marionette_driver.transport import TcpTransport

spec = importlib.util.spec_from_file_location("session_reset", Path(__file__).parents[1] / "src" / "reset_session.py")
session_reset = importlib.util.module_from_spec(spec)
spec.loader.exec_module(session_reset)


class Peer:
    def __init__(self, error=None, application="gecko"):
        self.error, self.application = error, application
        self.commands = []
        self.socket = socket.socket()
        self.socket.bind(("127.0.0.1", 0))
        self.port = self.socket.getsockname()[1]
        self.socket.listen(1)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    @staticmethod
    def send(client, data):
        encoded = json.dumps(data).encode()
        client.sendall(str(len(encoded)).encode() + b":" + encoded)

    def serve(self):
        client, _ = self.socket.accept()
        with client:
            self.send(client, {"applicationType": self.application, "marionetteProtocol": 3})
            prefix = bytearray()
            while True:
                byte = client.recv(1)
                if not byte:
                    return
                if byte == b":":
                    break
                prefix.extend(byte)
            remaining = int(prefix)
            body = bytearray()
            while remaining:
                chunk = client.recv(remaining)
                if not chunk:
                    return
                body.extend(chunk)
                remaining -= len(chunk)
            packet = json.loads(body)
            self.commands.append(packet[2])
            self.send(client, [1, packet[1], self.error, {}])

    def run(self):
        try:
            return session_reset.main(lambda host, port, **options: TcpTransport(host, self.port, **options))
        finally:
            self.thread.join(2)
            self.socket.close()


class ResetSessionTest(unittest.TestCase):
    def test_official_transport_resets_without_new_session_or_browser_commands(self):
        peer = Peer()
        result = peer.run()
        self.assertTrue(result["deleteSessionCompleted"])
        self.assertEqual(peer.commands, ["WebDriver:DeleteSession"])

    def test_already_clear_is_success_without_fabricating_a_deletion(self):
        result = Peer(error={"error": "invalid session id", "message": "private data"}).run()
        self.assertTrue(result["sessionAlreadyClear"])
        self.assertFalse(result["deleteSessionCompleted"])

    def test_provider_error_does_not_echo_private_message(self):
        result = Peer(error={"error": "unknown error", "message": "private data"}).run()
        self.assertFalse(result["ok"])
        self.assertNotIn("private data", json.dumps(result))

    def test_an_unexpected_endpoint_is_rejected_before_any_command(self):
        peer = Peer(application="other")
        with self.assertRaises(ValueError):
            peer.run()
        self.assertEqual(peer.commands, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
