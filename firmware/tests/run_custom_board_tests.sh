#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .pio/host-tests
json_headers=".pio/libdeps/m5paper-v1/ArduinoJson/src"
if [ ! -d "$json_headers" ]; then
    echo "Build m5paper-v1 once with PlatformIO to restore ArduinoJson headers." >&2
    exit 1
fi
for test in custom_board remote_network_queue remote_computer reference_lifecycle device_controls; do
    "${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -fsanitize=address,undefined \
        -I"$json_headers" "tests/${test}_test.cpp" -o ".pio/host-tests/${test}_test"
    if [ "$test" = custom_board ]; then
        ".pio/host-tests/${test}_test" ../protocol/fixtures/remote-profile-v7-screenless.json \
            ../protocol/fixtures/device-descriptor-v1-screenless.json \
            ../protocol/fixtures/device-descriptor-v1-landscape.json
    elif [ "$test" = device_controls ]; then
        ".pio/host-tests/${test}_test" .pio/host-tests
    else
        ".pio/host-tests/${test}_test"
    fi
done
"${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -Itests/stubs tests/reference_inputs_test.cpp -o .pio/host-tests/reference_inputs_test
.pio/host-tests/reference_inputs_test
"${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -Itests/stubs tests/supermini_s3_inputs_test.cpp -o .pio/host-tests/supermini_s3_inputs_test
.pio/host-tests/supermini_s3_inputs_test
python="../.venv/bin/python"
if [ -x "$python" ] && "$python" -c "import jsonschema" 2>/dev/null; then
    "$python" tests/validate_firmware_descriptors.py .pio/host-tests
else
    echo "Skipping descriptor schema validation: ../.venv with jsonschema not found." >&2
fi
