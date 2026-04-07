FROM ubuntu:latest

RUN apt-get update && apt-get install -y curl git mariadb-client python3 python3-pip python3-venv
RUN curl -sSL https://get.docker.com/ | CHANNEL=stable sh

RUN apt remove -y docker-compose-plugin && apt install -y docker-compose-v2

RUN mkdir -p /opt/ && cd /opt/ && git clone https://github.com/mailcow/mailcow-dockerized mailcow
RUN cd /opt/mailcow && git checkout legacy -f && cd /opt/

RUN mkdir -p /app && python3 -m venv /app/venv && /app/venv/bin/pip install python-keycloak fastapi uvicorn[standard] twisted ldaptor mysql-connector-python
COPY ./edulution-mailcow-sync /app
COPY ./templates /templates
COPY ./ldap-server.py /app/ldap-server.py

COPY ./entrypoint.sh entrypoint.sh
RUN chmod +x entrypoint.sh
RUN chmod +x /app/delete_from_file.py
ENTRYPOINT [ "./entrypoint.sh" ]
