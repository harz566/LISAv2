from pathlib import Path
from typing import Any

import yaml

from lisa.environment import Environment
from lisa.platform_ import Platform
from lisa.util import constants


class AzurePlatform(Platform):
    @classmethod
    def platform_type(cls) -> str:
        return constants.PLATFORM_AZURE

    def config(self, key: str, value: object) -> None:
        pass

    @property
    def extended_schema(self) -> Any:
        schema_path = Path(__file__).parent.joinpath("schema.yml")
        with open(schema_path, "r") as f:
            schema = yaml.safe_load(f)
        return schema

    def _request_environment_internal(self, environment: Environment) -> Environment:
        pass

    def _delete_environment_internal(self, environment: Environment) -> None:
        pass
