import logging

from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler
from pyftpdlib.servers import ThreadedFTPServer

logging.basicConfig(level=logging.WARNING)

authorizer = DummyAuthorizer()
authorizer.add_user("ftpu", "ftppw", "/home/ftpu", perm="elradfmwMT")

handler = FTPHandler
handler.authorizer = authorizer
handler.passive_ports = range(21100, 23000)

server = ThreadedFTPServer(("0.0.0.0", 2121), handler)
server.max_cons = 500
server.max_cons_per_ip = 500
server.serve_forever()
