from argparse import Namespace
from collections import UserDict
from pathlib import Path
from typing import TYPE_CHECKING, Dict, List, Optional, cast

import yaml

from lisa.schema import validate_config
from lisa.util import constants
from lisa.util.logger import get_logger

if TYPE_CHECKING:
    ConfigDict = UserDict[str, object]
else:
    ConfigDict = UserDict


class Config(ConfigDict):
    def __init__(
        self,
        base_path: Optional[Path] = None,
        config: Optional[Dict[str, object]] = None,
    ) -> None:
        super().__init__()
        if base_path is not None:
            self.base_path = base_path
        if config is not None:
            self._config: Dict[str, object] = config

    def validate(self) -> None:
        # TODO implement config validation
        pass

    @property
    def extension(self) -> Dict[str, object]:
        return self._get_and_cast(constants.EXTENSION)

    @property
    def environment(self) -> Dict[str, object]:
        return self._get_and_cast(constants.ENVIRONMENT)

    @property
    def platform(self) -> List[Dict[str, object]]:
        return cast(
            List[Dict[str, object]], self._config.get(constants.PLATFORM, list())
        )

    @property
    def testcase(self) -> Dict[str, object]:
        return self._get_and_cast(constants.TESTCASE)

    # TODO: This is a hack to get around our data not being
    # structured. Since we generally know the type of the data we’re
    # trying to get, this indicates that we need to properly structure
    # said data. Doing so correctly will enable us to delete this.
    def _get_and_cast(self, name: str) -> Dict[str, object]:
        return cast(Dict[str, object], self._config.get(name, dict()))


def parse_to_config(args: Namespace) -> Config:
    path = Path(args.config).absolute()
    log = get_logger("parser")

    log.info(f"load config from: {path}")
    if not path.exists():
        raise FileNotFoundError(path)

    with open(path, "r") as file:
        data = yaml.safe_load(file)

    # load schema
    validate_config(data)

    log.debug(f"final config data: {data}")
    base_path = path.parent
    log.debug(f"base path is {base_path}")
    return Config(base_path, data)
