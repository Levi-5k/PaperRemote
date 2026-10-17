#!/usr/bin/env python3

import json
import hashlib
import math
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

    validate_devices(protocol_directory, schema)


def validate_devices(protocol_directory: Path, profile_schema: dict) -> None:
    schemas = [profile_schema]
    for name in ["device-descriptor-v1", "board-catalog-v1", "remote-profile-v7", "device-controls-v1"]:
        schema = json.loads((protocol_directory / f"{name}.schema.json").read_text(encoding="utf-8"))
        Draft202012Validator.check_schema(schema)
        schemas.append(schema)
    registry = Registry().with_resources([
        (schema["$id"], Resource.from_contents(schema)) for schema in schemas
    ])
    validators = {
        schema["$id"].rsplit("/", 1)[-1]: Draft202012Validator(
            schema, registry=registry, format_checker=FormatChecker()
        ) for schema in schemas
    }
    descriptors = {}
    for path in sorted((protocol_directory / "fixtures").glob("device-descriptor-v1-*.json")):
        descriptor = json.loads(path.read_text(encoding="utf-8"))
        validators["device-descriptor-v1.schema.json"].validate(descriptor)
        validate_descriptor(descriptor)
        descriptors[(descriptor["boardID"], descriptor["hardwareRevision"])] = descriptor
        print(f"validated {path.name}")
    controls_fixture = descriptors[("fixture.controls", "1")]
    for path in sorted((protocol_directory / "fixtures").glob("device-controls-v1-*.json")):
        message = json.loads(path.read_text(encoding="utf-8"))
        validators["device-controls-v1.schema.json"].validate(message)
        if "values" in message:
            validate_control_values(message["values"], controls_fixture)
        if "id" in message:
            validate_control_values({message["id"]: message["value"]}, controls_fixture, writing=True)
        print(f"validated {path.name}")
    for path in sorted((protocol_directory / "fixtures").glob("remote-profile-v7-*.json")):
        profile = json.loads(path.read_text(encoding="utf-8"))
        validators["remote-profile-v7.schema.json"].validate(profile)
        bindings = profile["hardwareBindings"]
        identities = [(binding["inputID"], binding["event"], binding.get("direction")) for binding in bindings]
        if len(set(identities)) != len(identities):
            raise RuntimeError(f"{path.name}: duplicate hardware binding")
        for binding in bindings:
            if not binding["minimum"] < binding["maximum"] or not 0 < binding["step"] <= binding["maximum"] - binding["minimum"]:
                raise RuntimeError(f"{path.name}: invalid binding range")
        print(f"validated {path.name}")
    boards_directory = protocol_directory.parent / "boards"
    index = json.loads((boards_directory / "index.json").read_text(encoding="utf-8"))
    validators["board-catalog-v1.schema.json"].validate(index)
    seen = set()
    for entry in index["boards"]:
        if ".." in entry["path"]:
            raise RuntimeError("Catalog path must not contain traversal segments")
        path = boards_directory / entry["path"]
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != entry["sha256"]:
            raise RuntimeError(f"{path.name}: board digest mismatch")
        board = json.loads(data)
        validators["board-catalog-v1.schema.json"].validate(board)
        if board["boardID"] != entry["boardID"] or board["version"] != entry["version"] or board["hardwareRevisions"] != entry["hardwareRevisions"]:
            raise RuntimeError(f"{path.name}: catalog/package identity mismatch")
        for revision in entry["hardwareRevisions"]:
            identity = (entry["boardID"], revision, entry["version"])
            if identity in seen:
                raise RuntimeError(f"{path.name}: ambiguous catalog match")
            seen.add(identity)
            descriptor = descriptors.get((entry["boardID"], revision))
            if descriptor:
                validate_layout(board["layout"], descriptor)
        bundled = protocol_directory.parent / "device-kit/Sources/PaperDeviceKit/Boards" / entry["path"]
        if bundled.read_bytes() != data:
            raise RuntimeError(f"{path.name}: run scripts/sync-board-resources.sh")
        print(f"validated board {path.name}")
    bundled_index = protocol_directory.parent / "device-kit/Sources/PaperDeviceKit/Boards/index.json"
    if bundled_index.read_bytes() != (boards_directory / "index.json").read_bytes():
        raise RuntimeError("Bundled board index is stale; run scripts/sync-board-resources.sh")


def validate_descriptor(descriptor: dict) -> None:
    inputs = descriptor["inputs"]
    if len({item["id"] for item in inputs}) != len(inputs):
        raise RuntimeError("Duplicate device input IDs")
    display = descriptor["display"]
    if display and display["width"] * display["height"] > 16_777_216:
        raise RuntimeError("Display exceeds pixel budget")
    for item in inputs:
        if item["kind"] in ["dial", "slider"] and not item["minimum"] < item["maximum"]:
            raise RuntimeError("Absolute input range is invalid")
    if "layout" in descriptor:
        validate_layout(descriptor["layout"], descriptor)
    controls = descriptor.get("controls", [])
    if len({item["id"] for item in controls}) != len(controls):
        raise RuntimeError("Duplicate device control IDs")
    for item in controls:
        if item["kind"] == "range":
            span = item["maximum"] - item["minimum"]
            if not span > 0 or not 0 < item["step"] <= span:
                raise RuntimeError(f"Control {item['id']} has an invalid range")
        if item["kind"] == "select":
            values = [option["value"] for option in item["options"]]
            if len(set(values)) != len(values):
                raise RuntimeError(f"Control {item['id']} has duplicate options")


def validate_control_values(values: dict, descriptor: dict, writing: bool = False) -> None:
    controls = {item["id"]: item for item in descriptor.get("controls", [])}
    for identifier, value in values.items():
        control = controls.get(identifier)
        if control is None or control["kind"] == "action":
            raise RuntimeError(f"Control value {identifier} is not a stateful control")
        if writing and control.get("readOnly"):
            raise RuntimeError(f"Control {identifier} is read-only")
        kind = control["kind"]
        if kind == "toggle" and not isinstance(value, bool):
            raise RuntimeError(f"Control {identifier} expects a boolean")
        if kind == "range" and (isinstance(value, bool) or not isinstance(value, (int, float))
                or not control["minimum"] <= value <= control["maximum"]):
            raise RuntimeError(f"Control {identifier} is out of range")
        if kind == "select" and value not in [option["value"] for option in control["options"]]:
            raise RuntimeError(f"Control {identifier} has an unknown option")


def validate_layout(layout: dict, descriptor: dict) -> None:
    input_ids = {item["id"] for item in descriptor["inputs"]}
    placements = layout["inputs"]
    if len({item["id"] for item in placements}) != len(placements):
        raise RuntimeError("Duplicate input placement")
    for item in placements:
        if item["id"] not in input_ids:
            raise RuntimeError("Layout refers to an unknown input")
    rectangles = placements + ([layout["screen"]] if "screen" in layout else [])
    for rect in rectangles:
        if not all(math.isfinite(rect[key]) for key in ["x", "y", "width", "height"]):
            raise RuntimeError("Non-finite layout geometry")
        if rect["x"] + rect["width"] > layout["width"] or rect["y"] + rect["height"] > layout["height"]:
            raise RuntimeError("Layout rectangle is outside board bounds")


if __name__ == "__main__":
    main()