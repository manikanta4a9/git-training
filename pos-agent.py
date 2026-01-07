import websocket
import json
import time
import threading
import signal
import sys
import subprocess
import tempfile
import base64
import os

# === CONFIG ===
WS_URL = "wss://rxzavnsfd3.execute-api.eu-west-2.amazonaws.com/dev"
RESTAURANT_NUMBER = "12"
DEVICE_ID = "device-001"
MACHINE_NAME = "POS-01"

# === GLOBAL FLAGS ===
running = True
ws_app = None


def send_heartbeat(ws):
    """Send heartbeat every 30 seconds while running."""
    while running:
        heartbeat_msg = {
            "action": "heartbeat",
            "restaurant_number": RESTAURANT_NUMBER,
            "device_id": DEVICE_ID,
            "timestamp": int(time.time()),
        }
        try:
            ws.send(json.dumps(heartbeat_msg))
            print(f"💓 Sent heartbeat at {time.strftime('%X')}")
        except Exception as e:
            print(f"⚠️ Heartbeat error: {e}")
            break
        time.sleep(30)


def run_received_script(script_name, encoded_script, ws, command_id=None):
    """Decode, execute, and send back results."""
    try:
        decoded_bytes = base64.b64decode(encoded_script)
        with tempfile.NamedTemporaryFile(delete=False, suffix=".py", mode="wb") as f:
            f.write(decoded_bytes)
            script_path = f.name

        print(f"📜 Received script: {script_name} → saved to {script_path}")

        # Execute script and capture output
        process = subprocess.run(
            [sys.executable, script_path],
            capture_output=True,
            text=True,
            timeout=60  # seconds
        )

        save_result_msg = {
            "action": "save_results",
            "restaurant_number": RESTAURANT_NUMBER,
            "device_id": DEVICE_ID,
            "command_id": command_id or "unknown",
            "script_name": script_name,
            "result_output": process.stdout.strip(),
            "stderr": process.stderr.strip(),
            "returncode": process.returncode,
            "timestamp": int(time.time()),
            "execution_status": "success" if process.returncode == 0 else "failed"
        }
        ws.send(json.dumps(save_result_msg))
        print("💾 Sent results for saving to DynamoDB")

    except subprocess.TimeoutExpired:
        print(f"⏱️ Script {script_name} timed out.")
        ws.send(json.dumps({
            "action": "save_results",
            "command_id": command_id or "unknown",
            "device_id": DEVICE_ID,
            "machine": MACHINE_NAME,
            "script_name": script_name,
            "stderr": "Timeout expired",
            "timestamp": int(time.time())
        }))
    except Exception as e:
        print(f"❌ Error running received script: {e}")
        ws.send(json.dumps({
            "action": "save_results",
            "command_id": command_id or "unknown",
            "device_id": DEVICE_ID,
            "machine": MACHINE_NAME,
            "script_name": script_name,
            "stderr": str(e),
            "timestamp": int(time.time())
        }))
    finally:
        # Cleanup temp file
        if os.path.exists(script_path):
            os.remove(script_path)


def on_message(ws, message):
    """Handle incoming messages from WebSocket."""
    print(f"📩 From server: {message}")
    try:
        data = json.loads(message)
        action = data.get("action")

        if action == "run_script":
            script_name = data.get("script_name", "unknown.py")
            encoded_script = data.get("script_content", "")
            command_id = data.get("command_id")  # ✅ Extract command_id
            threading.Thread(
                target=run_received_script, args=(script_name, encoded_script, ws, command_id), daemon=True
            ).start()
        else:
            # print all other types (register/pong etc)
            print(f"ℹ️ Received message type: {action}")
    except Exception as e:
        print(f"⚠️ Failed to parse message: {e}")


def on_error(ws, error):
    if running:
        print(f"❌ Error: {error}")


def on_close(ws, close_status_code, close_msg):
    print("🔌 Connection closed gracefully.")


def on_open(ws):
    """Register device when connection opens."""
    print("✅ Connected to WebSocket")

    register_msg = {
        "action": "register",
        "restaurant_number": RESTAURANT_NUMBER,
        "device_id": DEVICE_ID,
        "machine": MACHINE_NAME,
    }
    ws.send(json.dumps(register_msg))
    print(f"📤 Sent registration for {MACHINE_NAME}")

    # Start heartbeat thread
    threading.Thread(target=send_heartbeat, args=(ws,), daemon=True).start()


def signal_handler(sig, frame):
    """Handle Ctrl+C / termination."""
    global running, ws_app
    print("\n⚙️ Shutting down gracefully...")

    running = False
    try:
        disconnect_msg = {
            "action": "disconnect",
            "restaurant_number": RESTAURANT_NUMBER,
            "device_id": DEVICE_ID,
        }
        ws_app.send(json.dumps(disconnect_msg))
        print("📤 Sent disconnect message to server")

        ws_app.close()
    except Exception as e:
        print(f"⚠️ Error during close: {e}")
    finally:
        sys.exit(0)


if __name__ == "__main__":
    websocket.enableTrace(False)

    # Attach Ctrl+C handler
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    url = f"{WS_URL}?restaurantnumber={RESTAURANT_NUMBER}&deviceid={DEVICE_ID}&machine={MACHINE_NAME}"
    ws_app = websocket.WebSocketApp(
        url,
        on_open=on_open,
        on_message=on_message,
        on_error=on_error,
        on_close=on_close,
    )

    print("🚀 Connecting to WebSocket...")
    ws_app.run_forever(ping_interval=60, ping_timeout=10)
