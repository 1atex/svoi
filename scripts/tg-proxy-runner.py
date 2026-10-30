import argparse
import asyncio
import json
import logging
import re
import sys
import threading

from proxy import tg_ws_proxy
from proxy.config import proxy_config


async def serve():
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()

    def watch_parent():
        sys.stdin.buffer.read()
        if not loop.is_closed():
            loop.call_soon_threadsafe(stop.set)

    threading.Thread(target=watch_parent, daemon=True).start()
    task = asyncio.create_task(tg_ws_proxy._run(stop))
    while not task.done() and tg_ws_proxy._server_instance is None:
        await asyncio.sleep(0.05)
    if not task.done():
        print('SVOI_TG_READY', flush=True)
    await task


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', required=True)
    args = parser.parse_args()
    with open(args.config, encoding='utf-8') as stream:
        settings = json.load(stream)
    port, secret = settings['port'], settings['secret']
    if type(port) is not int or not 1024 <= port <= 65535:
        raise ValueError('Invalid local port')
    if not isinstance(secret, str) or not re.fullmatch('[0-9a-f]{32}', secret):
        raise ValueError('Invalid local proxy secret')
    proxy_config.host = '127.0.0.1'
    proxy_config.port = port
    proxy_config.secret = secret
    logging.basicConfig(level=logging.INFO, format='%(levelname)s %(message)s')
    logging.getLogger('httpx').setLevel(logging.WARNING)
    logging.getLogger('httpcore').setLevel(logging.WARNING)
    asyncio.run(serve())


if __name__ == '__main__':
    main()
