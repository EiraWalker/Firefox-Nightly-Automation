"""Reset the explicitly authorized shared session through Mozilla's public transport."""
import json
from marionette_driver.transport import TcpTransport


def main(transport_factory=TcpTransport):
    transport = transport_factory("127.0.0.1", 2828, socket_timeout=10)
    try:
        protocol, application = transport.connect()
        if protocol != 3 or application != "gecko":
            raise RuntimeError("F_MARIONETTE_UNEXPECTED")
        response = transport.request("WebDriver:DeleteSession", {})
        if response.error:
            code = response.error.get("error") if isinstance(response.error, dict) else None
            if code == "invalid session id":
                return {"ok": True, "deleteSessionCompleted": False, "sessionAlreadyClear": True, "protocol": protocol}
            return {"ok": False, "error": "F_SESSION_RESET_FAILED", "remoteCode": code if isinstance(code, str) else None}
        return {"ok": True, "deleteSessionCompleted": True, "protocol": protocol}
    finally:
        transport.close()


if __name__ == "__main__":
    try:
        result = main()
        print(json.dumps(result))
        if not result["ok"]:
            raise SystemExit(1)
    except Exception:
        # SDK/remote exceptions can contain private data; expose only the stage.
        print(json.dumps({"ok": False, "error": "F_SESSION_RESET_FAILED"}))
        raise SystemExit(1)
