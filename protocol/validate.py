#!/usr/bin/env python3

import json
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource


def main() -> None:
    protocol_directory = Path(__file__).resolve().parent
    schema_path = protocol_directory / "remote-profile-v6.schema.json"
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema, format_checker=FormatChecker())

    fixture_paths = sorted((protocol_directory / "fixtures").glob("remote-profile-v6-*.json"))
    if not fixture_paths:
        raise RuntimeError("No v6 remote-profile fixtures were found.")

    for fixture_path in fixture_paths:
        fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
        errors = sorted(validator.iter_errors(fixture), key=lambda error: list(error.path))
        if errors:
            details = "\n".join(
                f"{fixture_path.name}:{'/'.join(map(str, error.path))}: {error.message}"
                for error in errors
            )
            raise RuntimeError(details)
        print(f"validated {fixture_path.name}")

    module_schema_path = protocol_directory / "module-manifest-v1.schema.json"
    module_schema = json.loads(module_schema_path.read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(module_schema)
    profile_resource = Resource.from_contents(schema)
    registry = Registry().with_resources([
        (schema["$id"], profile_resource),
        (
            "https://raw.githubusercontent.com/Levi-5k/PaperRemote/main/protocol/remote-profile-v6.schema.json",
            profile_resource,
        ),
    ])
    module_validator = Draft202012Validator(
        module_schema,
        registry=registry,
        format_checker=FormatChecker(),
    )
    module_paths = sorted(protocol_directory.parent.joinpath("modules").glob("*.json"))
    for module_path in module_paths:
        if module_path.name == "index.json":
            continue
        module = json.loads(module_path.read_text(encoding="utf-8"))
        errors = sorted(module_validator.iter_errors(module), key=lambda error: list(error.path))
        if errors:
            details = "\n".join(
                f"{module_path.name}:{'/'.join(map(str, error.path))}: {error.message}"
                for error in errors
            )
            raise RuntimeError(details)
        print(f"validated {module_path.name}")


if __name__ == "__main__":
    main()