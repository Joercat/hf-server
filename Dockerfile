FROM debian:12-slim
ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

RUN mkdir -p /usr/share/binfmts && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        openjdk-17-jdk-headless \
        wget \
        curl \
        netcat-openbsd \
        procps \
        python3 \
        python3-pip \
        python3-setuptools \
        python3-wheel \
        ca-certificates && \
    dpkg --configure -a || true && \
    rm -rf /var/lib/apt/lists/* && \
    apt-get clean

RUN pip3 install --no-cache-dir --break-system-packages "huggingface_hub[cli]>=1.5.0"

# RCON client
RUN printf '#!/usr/bin/env python3\n\
import socket, struct, sys, argparse\n\
\n\
\ndef rcon(host, port, password, command):\n\
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)\n\
    s.settimeout(5)\n\
    s.connect((host, int(port)))\n\
    payload = struct.pack("<ii", 0, 3) + password.encode("utf-8") + b"\\x00\\x00"\n\
    s.send(struct.pack("<i", len(payload)) + payload)\n\
    resp = s.recv(4096)\n\
    payload = struct.pack("<ii", 1, 2) + command.encode("utf-8") + b"\\x00\\x00"\n\
    s.send(struct.pack("<i", len(payload)) + payload)\n\
    resp = s.recv(4096)\n\
    if len(resp) >= 12:\n\
        return resp[12:].decode("utf-8", errors="ignore").rstrip("\\x00")\n\
    return ""\n\
\n\
\nif __name__ == "__main__":\n\
    p = argparse.ArgumentParser()\n\
    p.add_argument("-H", "--host", default="127.0.0.1")\n\
    p.add_argument("-P", "--port", default="25575")\n\
    p.add_argument("-p", "--password", default="")\n\
    p.add_argument("commands", nargs="*")\n\
    args = p.parse_args()\n\
    for cmd in args.commands:\n\
        try:\n\
            result = rcon(args.host, int(args.port), args.password, cmd)\n\
            if result:\n\
                print(result)\n\
        except Exception as e:\n\
            print("RCON error: " + str(e), file=sys.stderr)\n' > /usr/local/bin/mcrcon && chmod +x /usr/local/bin/mcrcon

WORKDIR /opt/server
RUN mkdir -p /opt/server/bungee/plugins /opt/server/backend/plugins

# BungeeCord
RUN wget -O /opt/server/bungee/BungeeCord.jar \
    "https://ci.md-5.net/job/BungeeCord/1892/artifact/bootstrap/target/BungeeCord.jar"

RUN wget -O /opt/server/bungee/sqlite-jdbc.jar \
    "https://github.com/xerial/sqlite-jdbc/releases/download/3.45.3.0/sqlite-jdbc-3.45.3.0.jar"

RUN mkdir -p /opt/server/bungee/modules && \
    wget -O /opt/server/bungee/modules/cmd_alert.jar \
        "https://ci.md-5.net/job/BungeeCord/1892/artifact/module/cmd-alert/target/cmd_alert.jar" && \
    wget -O /opt/server/bungee/modules/cmd_find.jar \
        "https://ci.md-5.net/job/BungeeCord/1892/artifact/module/cmd-find/target/cmd_find.jar" && \
    wget -O /opt/server/bungee/modules/cmd_list.jar \
        "https://ci.md-5.net/job/BungeeCord/1892/artifact/module/cmd-list/target/cmd_list.jar" && \
    wget -O /opt/server/bungee/modules/cmd_send.jar \
        "https://ci.md-5.net/job/BungeeCord/1892/artifact/module/cmd-send/target/cmd_send.jar" && \
    wget -O /opt/server/bungee/modules/cmd_server.jar \
        "https://ci.md-5.net/job/BungeeCord/1892/artifact/module/cmd-server/target/cmd_server.jar" && \
    wget -O /opt/server/bungee/modules/reconnect_yaml.jar \
        "https://ci.md-5.net/job/BungeeCord/1892/artifact/module/reconnect-yaml/target/reconnect_yaml.jar"

# Paper 1.12.2 (Replaced WindSpigot)
RUN wget -O /opt/server/backend/server.jar \
    "https://fill-data.papermc.io/v1/objects/3a2041807f492dcdc34ebb324a287414946e3e05ec3df6fd03f5b5f7d9afc210/paper-1.12.2-1620.jar"

# Updated Mojang API download link for the 1.12.2 Vanilla server.jar cache
RUN mkdir -p /opt/server/backend/cache && \
    wget -O /opt/server/backend/cache/mojang_1.12.2.jar \
        "https://piston-data.mojang.com/v1/objects/886945bfb2b978778c3a0288fd7fab09d315b25f/server.jar" || true

COPY plugins/ /opt/server/backend/plugins/

# EaglerXBungee
COPY config/bungee/EaglerXBungee.jar /opt/server/bungee/plugins/EaglerXBungee.jar

# NOTE: client/1.12.html is deliberately NOT copied into the image (and does
# not have to exist in the Space). It is your private client - publishing it
# in the Space repo would hand the verified brand to everybody - so it lives
# in the bucket or on your machine, see README "What to upload to the Space".
# Keeping it out also means the Space can be updated file by file without
# uploading the 22 MB client every time.

RUN printf 'server_connect_timeout: 5000\n\
online_mode: false\n\
listeners:\n\
- host: 127.0.0.1:25577\n\
  max_players: 10\n\
servers:\n\
  lobby:\n\
    address: 127.0.0.1:25565\n\
    motd: Server\n\
    restricted: false\n' > /opt/server/bungee/config.yml

RUN echo "eula=true" > /opt/server/backend/eula.txt

COPY start.sh /opt/server/start.sh
RUN chmod +x /opt/server/start.sh
RUN chmod -R 755 /opt/server

EXPOSE 7860

CMD ["/opt/server/start.sh"]
