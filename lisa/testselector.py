import re
from functools import partial
from typing import (
    Any,
    Callable,
    Dict,
    List,
    Mapping,
    Optional,
    Pattern,
    Set,
    Union,
    cast,
)

from lisa.testsuite import TestCaseData, TestCaseMetadata, get_cases_metadata
from lisa.util import constants
from lisa.util.exceptions import LisaException
from lisa.util.logger import get_logger

_get_logger = partial(get_logger, "init", "selector")


def select_testcases(
    filters: Any = None, init_cases: Optional[List[TestCaseMetadata]] = None
) -> List[TestCaseData]:
    """
    based on filters to select test cases. If filters are None, return all cases.
    """
    results: List[TestCaseData] = []
    log = _get_logger()
    if init_cases:
        full_list: Dict[str, TestCaseMetadata] = dict()
        for item in init_cases:
            full_list[item.full_name] = item
    else:
        full_list = get_cases_metadata()
    if filters:
        selected: Dict[str, TestCaseData] = dict()
        force_included: Set[str] = set()
        force_excluded: Set[str] = set()
        for filter in filters:
            filter = cast(Dict[str, Any], filter)
            enabled = filter.get(constants.ENABLE, True)
            if enabled:
                selected = _apply_filter(
                    filter, selected, force_included, force_excluded, full_list
                )
            else:
                log.debug(f"skip disabled rule: {filter}")
        log.info(f"selected cases count: {len(list(selected.values()))}")
        results = list(selected.values())
    else:
        for metadata in full_list.values():
            results.append(TestCaseData(metadata))

    return results


def _match_string(
    case: Union[TestCaseData, TestCaseMetadata], pattern: Pattern[str], attr_name: str,
) -> bool:
    content = cast(str, getattr(case, attr_name))
    match = pattern.fullmatch(content)
    return match is not None


def _match_priority(
    case: Union[TestCaseData, TestCaseMetadata], pattern: Union[int, List[int]]
) -> bool:
    priority = case.priority
    is_matched: bool = False
    if isinstance(pattern, int):
        is_matched = priority == pattern
    else:
        is_matched = any(x == priority for x in pattern)
    return is_matched


def _match_tag(
    case: Union[TestCaseData, TestCaseMetadata], criteria_tags: Union[str, List[str]]
) -> bool:
    case_tags = case.tags
    is_matched: bool = False
    if isinstance(criteria_tags, str):
        is_matched = criteria_tags in case_tags
    else:
        is_matched = any(x in case_tags for x in criteria_tags)
    return is_matched


def _match_cases(
    candidates: Mapping[str, Union[TestCaseData, TestCaseMetadata]],
    patterns: List[Callable[[Union[TestCaseData, TestCaseMetadata]], bool]],
) -> Dict[str, TestCaseData]:
    changed_cases: Dict[str, TestCaseData] = dict()

    for candidate_name in candidates:
        candidate = candidates[candidate_name]
        is_matched = all(pattern(candidate) for pattern in patterns)
        if is_matched:
            if isinstance(candidate, TestCaseMetadata):
                candidate = TestCaseData(candidate)
            changed_cases[candidate_name] = candidate
    return changed_cases


def _apply_settings(
    applied_case_data: TestCaseData, config: Dict[str, Any], action: str
) -> None:
    field_mapping = {
        "times": constants.TESTCASE_TIMES,
        "retry": constants.TESTCASE_RETRY,
        "use_new_environmnet": constants.TESTCASE_USE_NEW_ENVIRONMENT,
        "ignore_failure": constants.TESTCASE_IGNORE_FAILURE,
        "environment": constants.ENVIRONMENT,
    }
    for (attr_name, schema_name) in field_mapping.items():
        schema_value = config.get(schema_name)
        if schema_value:
            setattr(applied_case_data, attr_name, schema_value)

    # use default value from selector
    applied_case_data.select_action = action


def _force_check(
    name: str,
    is_force: bool,
    force_expected_set: Set[str],
    force_exclusive_set: Set[str],
    temp_force_exclusive_set: Set[str],
    config: Any,
) -> bool:
    is_skip = False
    if name in force_exclusive_set:
        if is_force:
            raise LisaException(f"case {name} has force conflict on {config}")
        else:
            temp_force_exclusive_set.add(name)
        is_skip = True
    if not is_skip and is_force:
        force_expected_set.add(name)
    return is_skip


def _apply_filter(
    config: Dict[str, Any],
    current_selected: Dict[str, TestCaseData],
    force_included: Set[str],
    force_excluded: Set[str],
    full_list: Dict[str, TestCaseMetadata],
) -> Dict[str, TestCaseData]:

    log = _get_logger()
    # initialize criterias
    patterns: List[Callable[[Union[TestCaseData, TestCaseMetadata]], bool]] = []
    criterias_config: Dict[str, Any] = config.get(constants.TESTCASE_CRITERIA, dict())
    for config_key in criterias_config:
        if config_key in [
            constants.NAME,
            constants.TESTCASE_CRITERIA_AREA,
            constants.TESTCASE_CRITERIA_CATEGORY,
        ]:
            pattern = cast(str, criterias_config[config_key])
            expression = re.compile(pattern)
            patterns.append(
                partial(_match_string, pattern=expression, attr_name=config_key)
            )
        elif config_key == constants.TESTCASE_CRITERIA_PRIORITY:
            priority_pattern = cast(Union[int, List[int]], criterias_config[config_key])
            patterns.append(partial(_match_priority, pattern=priority_pattern))
        elif config_key == constants.TESTCASE_CRITERIA_TAG:
            tag_pattern = cast(Union[str, List[str]], criterias_config[config_key])
            patterns.append(partial(_match_tag, criteria_tags=tag_pattern))
        else:
            raise LisaException(f"unknown criteria key: {config_key}")

    # match by select Action:
    changed_cases: Dict[str, TestCaseData] = dict()
    action = config.get(
        constants.TESTCASE_SELECT_ACTION, constants.TESTCASE_SELECT_ACTION_INCLUDE
    )
    is_force = action in [
        constants.TESTCASE_SELECT_ACTION_FORCE_INCLUDE,
        constants.TESTCASE_SELECT_ACTION_FORCE_EXCLUDE,
    ]
    is_update_setting = action in [
        constants.TESTCASE_SELECT_ACTION_NONE,
        constants.TESTCASE_SELECT_ACTION_INCLUDE,
        constants.TESTCASE_SELECT_ACTION_FORCE_INCLUDE,
    ]
    temp_force_set: Set[str] = set()
    if action is constants.TESTCASE_SELECT_ACTION_NONE:
        # Just apply settings on test cases
        changed_cases = _match_cases(current_selected, patterns)
    elif action in [
        constants.TESTCASE_SELECT_ACTION_INCLUDE,
        constants.TESTCASE_SELECT_ACTION_FORCE_INCLUDE,
    ]:
        # to include cases
        changed_cases = _match_cases(full_list, patterns)
        for name, new_case_data in changed_cases.items():
            is_skip = _force_check(
                name, is_force, force_included, force_excluded, temp_force_set, config
            )
            if is_skip:
                continue

            # reuse original test cases
            case_data = current_selected.get(name, new_case_data)
            current_selected[name] = case_data
            changed_cases[name] = case_data
    elif action in [
        constants.TESTCASE_SELECT_ACTION_EXCLUDE,
        constants.TESTCASE_SELECT_ACTION_FORCE_EXCLUDE,
    ]:
        changed_cases = _match_cases(current_selected, patterns)
        for name in changed_cases:
            is_skip = _force_check(
                name, is_force, force_excluded, force_included, temp_force_set, config
            )
            if is_skip:
                continue
            del current_selected[name]
    else:
        raise LisaException(f"unknown selectAction: '{action}'")

    # changed set cannot be operated in it's for loop, so update it here.
    for name in temp_force_set:
        del changed_cases[name]
    if is_update_setting:
        for case_data in changed_cases.values():
            _apply_settings(case_data, config, action)

    log.debug(
        f"applying action: [{action}] on case [{changed_cases.keys()}], "
        f"config: {config}, loaded criteria count: {len(patterns)}"
    )

    return current_selected
