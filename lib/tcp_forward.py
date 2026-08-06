import argparse
import socket
import threading
import sys

BUFFER_SIZE = 65536

def relay(src: socket.socket, dst: socket.socket):
    try:
        while True:
            data = src.recv(BUFFER_SIZE)
            if not data:
                break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except Exception:
                pass
            try:
                s.close()
            except Exception:
                pass

def handle_client(client_sock: socket.socket, client_addr, target_host, target_port, allowed_clients):
    try:
        if allowed_clients and client_addr[0] not in allowed_clients:
            client_sock.close()
            return

        upstream = socket.create_connection((target_host, target_port), timeout=5)

        # The 5s above is a CONNECT timeout, but create_connection leaves the socket in
        # timeout mode, so it would also apply to every recv() in the relay loop below.
        # Any connection idle for 5s then dies: a human typing a password, an idle SSH
        # tunnel, a keep-alive HTTP socket. Restore blocking mode now that we're connected.
        upstream.settimeout(None)
        client_sock.settimeout(None)

        t1 = threading.Thread(target=relay, args=(client_sock, upstream), daemon=True)
        t2 = threading.Thread(target=relay, args=(upstream, client_sock), daemon=True)
        t1.start()
        t2.start()
    except Exception:
        try:
            client_sock.close()
        except Exception:
            pass

def main():
    parser = argparse.ArgumentParser(description="Simple TCP forwarder (Windows -> WSL2)")
    parser.add_argument("--listen-host", default="0.0.0.0", help="Host/IP to listen on (default: 0.0.0.0)")
    parser.add_argument("--listen-port", type=int, default=8000, help="Port to listen on (default: 8000)")
    parser.add_argument("--target-host", required=True, help="Target host/IP (WSL IP, e.g. 172.26.220.46)")
    parser.add_argument("--target-port", type=int, default=8000, help="Target port (default: 8000)")
    parser.add_argument("--allow", action="append", default=[], help="Optional allowlist of client IPs; repeatable")
    args = parser.parse_args()

    allowed_clients = set(args.allow) if args.allow else set()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)

    try:
        srv.bind((args.listen_host, args.listen_port))
    except OSError as e:
        print(f"ERROR: could not bind {args.listen_host}:{args.listen_port} ({e})", file=sys.stderr)
        print("If this is 'address already in use', pick another listen port (e.g. 8080).", file=sys.stderr)
        sys.exit(1)

    srv.listen(50)
    print(f"Forwarding {args.listen_host}:{args.listen_port}  ->  {args.target_host}:{args.target_port}")
    if allowed_clients:
        print(f"Allowing clients: {sorted(allowed_clients)}")

    while True:
        client_sock, client_addr = srv.accept()
        threading.Thread(
            target=handle_client,
            args=(client_sock, client_addr, args.target_host, args.target_port, allowed_clients),
            daemon=True
        ).start()

if __name__ == "__main__":
    main()
