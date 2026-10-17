"""Validates descriptors and control messages emitted by tests/device_controls_test.cpp."""

import json
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / "protocol"))

from jsonschema import Draft202012Validator  # noqa: E402
from referencing import Registry, Resource  # noqa: E402
from validate import validate_control_values, validate_descriptor  # noqa: E402


def main() -> None:
    output = Path(sys.argv[1])
    protocol = root / "protocol"
    schemas = {
        name: json.loads((protocol / f"{name}.schema.json").read_text(encoding="utf-8"))
        for name in ["remote-profile-v7", "device-descriptor-v1", "device-controls-v1"]
    }
    registry = Registry().with_resources(
        [(schema["$id"], Resource.from_contents(schema)) for schema in schemas.values()]
    )
    descriptor_validator = Draft202012Validator(schemas["device-descriptor-v1"], registry=registry)
    controls_validator = Draft202012Validator(schemas["device-controls-v1"], registry=registry)
    descriptors = {}
    for name in ["m5paper", "reference", "supermini-s3"]:
        descriptor = json.loads((output / f"descriptor-{name}.json").read_text(encoding="utf-8"))
        descriptor_validator.validate(descriptor)
        validate_descriptor(descriptor)
        descriptors[name] = descriptor
    for name in ["snapshot", "set-response"]:
        message = json.loads((output / f"controls-m5paper-{name}.json").read_text(encoding="utf-8"))
        controls_validator.validate(message)
        validate_control_values(message["values"], descriptors["m5paper"])
    controls_validator.validate(json.loads((output / "controls-relay-action.json").read_text(encoding="utf-8")))
    print("firmware descriptors and control messages match the protocol schemas")


if __name__ == "__main__":
    main()
