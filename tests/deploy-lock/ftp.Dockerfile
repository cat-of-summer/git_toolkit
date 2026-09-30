FROM python:3.12-alpine

RUN pip install --no-cache-dir pyftpdlib==2.0.1 \
 && adduser -D ftpu \
 && mkdir -p /home/ftpu/site/ro \
 && chown -R ftpu:ftpu /home/ftpu \
 && chmod 555 /home/ftpu/site/ro

COPY ftp-server.py /usr/local/bin/ftp-server.py
USER ftpu
CMD ["python", "/usr/local/bin/ftp-server.py"]
