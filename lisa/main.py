import os
import sys
import time
from datetime import datetime
from argparse import ArgumentParser
from logging import DEBUG, INFO

import asyncio

from lisa import ActionStatus
from lisa.common.logger import init_log, log
from lisa.common import env
from lisa.test_runner.lisarunner import LISARunner
from retry import retry

path_template = "runtime/results/{0}/{0}-{1}"


@retry(FileExistsError, tries=10, delay=0)
def create_result_path():
    date = datetime.utcnow().strftime("%Y%m%d")
    time = datetime.utcnow().strftime("%H%M%S-%f")[:-3]
    current_path = path_template.format(date, time)
    if os.path.exists(current_path):
        raise FileExistsError(
            "%s exists, and not found an unique path." % current_path
        )
    return current_path


result_path = os.path.realpath(create_result_path())
os.makedirs(result_path)
env.set_env(env.RESULT_PATH, result_path)


async def run():
    init_log()
    log.info("Python version: %s" % sys.version)
    log.info("command line args: %s" % sys.argv)
    log.info("local time: %s", datetime.now())
    log.info("result path: %s", env.get_env(env.RESULT_PATH))

    # parse args run function.
    parser = ArgumentParser()
    parser.add_argument(
        "--verbose", "-v", action="store_true", help="set log level to debug"
    )
    args = parser.parse_args()
    if args.verbose:
        log_level = DEBUG
    else:
        log_level = INFO
    log.setLevel(log_level)
    log.info("set log level to %s", args.verbose)

    runner = LISARunner()
    await runner.start()
    while True:
        status = runner.getStatus()
        log.info("main status is %s", status.name)
        if status != ActionStatus.RUNNING:
            break
        time.sleep(1)
    log.info("result is %s", runner.exitCode)


if __name__ == "__main__":
    exitCode = 0
    try:
        loop = asyncio.get_event_loop()
        loop.run_until_complete(run())
        loop.close()
    except Exception as exception:
        log.exception(exception)
        exitCode = -1
    finally:
        # force all threads end.
        os._exit(exitCode)