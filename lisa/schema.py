import copy
import logging
from functools import partial
from pathlib import Path
from typing import Any, Dict, Optional

import yaml
from cerberus import Validator, schema_registry  # type: ignore

from lisa.platform_ import platforms
from lisa.util.exceptions import LisaException
from lisa.util.logger import get_logger

_schema: Optional[Dict[str, Any]] = None
_get_init_logger = partial(get_logger, "init", "schema")


def normalize_config(data: Any) -> Any:
    global _schema
    if not _schema:
        schema_path = Path(__file__).parent.joinpath("schema.yml")
        with open(schema_path, "r") as f:
            _schema = yaml.safe_load(f)

    _load_platform_schema(_schema)

    v = Validator(_schema)
    log = _get_init_logger()
    is_success = v.validate(data)
    if not is_success:
        log.lines(level=logging.ERROR, content=v.errors)
        raise LisaException("met validation errors, see error log for details")

    return v.document


def _load_platform_schema(schema: Any) -> None:
    log = _get_init_logger()

    # add extended schemas
    platform_extension_entry = schema["platform"]["schema"]["schema"]
    template_extension_entry = schema["environment"]["schema"]["environments"][
        "schema"
    ]["schema"]["template"]["schema"]
    nodes_extension_entry = schema["environment"]["schema"]["environments"]["schema"][
        "schema"
    ]["nodes"]["schema"]["oneof_schema"][2]
    for platform in platforms.values():
        platform_schema = platform.extended_schema
        log.debug(f"platform_schema: {platform_schema}")
        if platform_schema:
            # extended content
            rule_name = f"rule_{platform.platform_type()}"
            schema_registry.add(rule_name, platform_schema)
            added_schema = {
                "type": "dict",
                "schema": rule_name,
            }

            # extend platform
            platform_added_schema: Dict[str, Any] = copy.copy(added_schema)
            platform_added_schema["dependencies"] = {"type": [platform.platform_type()]}
            platform_extension_entry[platform.platform_type()] = platform_added_schema

            # extend environment
            template_extension_entry[platform.platform_type()] = added_schema
            nodes_extension_entry[platform.platform_type()] = added_schema
