#!/usr/bin/env bash
###
# File: 60-run-fluentd.sh
# Project: start
# File Created: Monday, 21st October 2024 9:46:22 pm
# Author: Josh5 (jsunnex@gmail.com)
# -----
# Last Modified: Tuesday, 22nd October 2024 4:45:04 pm
# Modified By: Josh5 (jsunnex@gmail.com)
###

# Check if we should perform a "nuclear clean" before running the installation
echo "--- Configure Fluentd Service ---"
if [ "${CUSTOM_LOG_DRIVER:-}" = "fluentd" ]; then
    echo "  - Configure fluentd container run aliases..."
    mkdir -p \
        ${fluentd_data_path:?}/log \
        ${fluentd_data_path:?}/etc \
        ${fluentd_data_path:?}/storage
    chown -R 999:999 ${fluentd_data_path:?}
    FLUENTD_RUN_CMD="${docker_cmd:?} run -d --rm --name ${fluentd_continer_name:?} \
        --memory 256m \
        --env FLUENTD_TAG=${FLUENTD_TAG:-sentry} \
        --volume ${fluentd_data_path:?}/log:/fluentd/log \
        --volume ${fluentd_data_path:?}/etc:/fluentd/etc \
        --volume ${fluentd_data_path:?}/storage:/fluentd/storage \
        --network ${custom_docker_network_name:?} \
        --network-alias ${fluentd_continer_name:?} \
        --publish 24224:24224 \
        --publish 24224:24224/udp \
        fluent/fluentd:${fluentd_image_tag:?}"

    echo "  - Installing fluentd config"
    cp -fv /defaults/fluentd/fluent.template.conf ${fluentd_data_path:?}/etc/fluent.conf
    if [ "X${FLUENTD_ADDITIONAL_SOURCE_TAGS:-}" != "X" ]; then
        echo "  - Add additional records ${FLUENTD_ADDITIONAL_SOURCE_TAGS:?} to record_transformer filter in fluentd config."
        IFS=',' read -ra pairs <<<"${FLUENTD_ADDITIONAL_SOURCE_TAGS:?}"
        for pair in "${pairs[@]}"; do
            key="${pair%%:*}"
            value="${pair##*:}"
            sed -i "/# <FLUENTD_ADDITIONAL_SOURCE_TAGS>/a \ \ \ \ \ \ \ \ \ \ \ \ source.${key} \"${value}\"" "${fluentd_data_path:?}/etc/fluent.conf"
        done
    fi

    echo "  - Setting tag prefix ${FLUENTD_TAG:-sentry} in fluentd config."
    sed -i "s|<FLUENTD_TAG>|${FLUENTD_TAG:-sentry}|" "${fluentd_data_path:?}/etc/fluent.conf"

    remote_output_configured="false"
    if [ "X${FLUENTD_FORWARD_ADDRESS:-}" != "X" ]; then
        echo "  - Configure a forward output in fluentd config."
        # Split the address into host and port
        fluentd_forward_host="${FLUENTD_FORWARD_ADDRESS%%:*}"
        fluentd_forward_port="${FLUENTD_FORWARD_ADDRESS##*:}"
        fluentd_forward_tmp=$(mktemp)
        echo "        <store>" >"$fluentd_forward_tmp"
        cat <<EOF >>"$fluentd_forward_tmp"
            @type                 forward
            send_timeout          20s
            recover_wait          10s
            hard_timeout          30s
            <buffer>
                @type             file
                path              /fluentd/storage/buffer
                flush_interval    5s
                chunk_limit_size  1m
                flush_at_shutdown true
            </buffer>
            <server>
                name              upstream
                weight            60
                host              ${fluentd_forward_host:?}
                port              ${fluentd_forward_port:?}
            </server>
EOF
        if [ "X${FLUENTD_FORWARD_SHARED_KEY:-}" != "X" ]; then
            # TODO: Add a variable to specify the hostname
            echo "            <security>" >>"$fluentd_forward_tmp"
            echo "                self_hostname     sentry-local" >>"$fluentd_forward_tmp"
            echo "                shared_key        ${FLUENTD_FORWARD_SHARED_KEY:?}" >>"$fluentd_forward_tmp"
            echo "            </security>" >>"$fluentd_forward_tmp"
        fi
        if [ "${FLUENTD_FORWARD_USE_TLS:-}" = "true" ]; then
            echo "            transport             tls" >>"$fluentd_forward_tmp"
            if [ "${FLUENTD_FORWARD_VERIFY_CERT:-}" = "true" ]; then
                echo "            tls_insecure_mode     false" >>"$fluentd_forward_tmp"
                if [ "${FLUENTD_FORWARD_VERIFY_CERT_HOSTNAME:-}" = "true" ]; then
                    echo "            tls_verify_hostname   true" >>"$fluentd_forward_tmp"
                fi
            else
                echo "            tls_insecure_mode     true" >>"$fluentd_forward_tmp"
            fi
        fi
        echo "        </store>" >>"$fluentd_forward_tmp"
        awk -v fwd_config="$fluentd_forward_tmp" '
        {
            if ($0 ~ /# <FLUENTD_FWD_CONFIG>/) {
                while ((getline line < fwd_config) > 0) print line;
                close(fwd_config)
            } else {
                print $0;
            }
        }' "${fluentd_data_path:?}/etc/fluent.conf" >"${fluentd_data_path:?}/etc/fluent.conf.tmp"
        mv "${fluentd_data_path:?}/etc/fluent.conf.tmp" "${fluentd_data_path:?}/etc/fluent.conf"
        rm "$fluentd_forward_tmp"
        remote_output_configured="true"
    else
        echo "  - No forward output created for fluentd config."
    fi

    if [ "X${FLUENTD_HTTP_ADDRESS:-}" != "X" ]; then
        echo "  - Configure a http output in fluentd config."
        # Split the address into host and port
        fluentd_http_tmp=$(mktemp)
        cat <<EOF >"$fluentd_http_tmp"
        <store>
            @type                   http
            endpoint                ${FLUENTD_HTTP_ADDRESS:?}
            http_method             post
            tls                     true
            tls_insecure_mode       true
            open_timeout            10
            read_timeout            30

            content_type            json
            json_array              true

            <format>
                @type               json
            </format>

            <buffer>
                @type               file
                path                /fluentd/storage/buffer
                flush_interval      5s
                chunk_limit_size    1m
                flush_at_shutdown   true
            </buffer>
        </store>
EOF
        awk -v fwd_config="$fluentd_http_tmp" '
        {
            if ($0 ~ /# <FLUENTD_HTTP_CONFIG>/) {
                while ((getline line < fwd_config) > 0) print line;
                close(fwd_config)
            } else {
                print $0;
            }
        }' "${fluentd_data_path:?}/etc/fluent.conf" >"${fluentd_data_path:?}/etc/fluent.conf.tmp"
        mv "${fluentd_data_path:?}/etc/fluent.conf.tmp" "${fluentd_data_path:?}/etc/fluent.conf"
        rm "$fluentd_http_tmp"
        remote_output_configured="true"
    else
        echo "  - No http output created for fluentd config."
    fi

    fluentd_stdout_tmp=$(mktemp)
    if [ "${remote_output_configured:-}" != "true" ]; then
        echo "  - Configure a stdout output as the only output in fluentd config."
        # Split the address into host and port
        cat <<EOF >"$fluentd_stdout_tmp"
        <store>
            @type stdout
        </store>
EOF
    else
        echo "  - Configure a stdout output as the fallback output in fluentd config."
        cat <<EOF >"$fluentd_stdout_tmp"
        <store ignore_if_prev_success ignore_error>
            @type stdout
        </store>
EOF
    fi
    awk -v fwd_config="$fluentd_stdout_tmp" '
    {
        if ($0 ~ /# <FLUENTD_STDOUT_CONFIG>/) {
            while ((getline line < fwd_config) > 0) print line;
            close(fwd_config)
        } else {
            print $0;
        }
    }' "${fluentd_data_path:?}/etc/fluent.conf" >"${fluentd_data_path:?}/etc/fluent.conf.tmp"
    mv "${fluentd_data_path:?}/etc/fluent.conf.tmp" "${fluentd_data_path:?}/etc/fluent.conf"
    rm "$fluentd_stdout_tmp"

    echo "  - Writing fluentd container config to env file"
    echo "" >${fluentd_data_path:?}/new-fluentd-docker-run-config.env
    echo "fluentd_image_tag=${fluentd_image_tag:?}" >>${fluentd_data_path:?}/new-fluentd-docker-run-config.env
    echo "FLUENTD_RUN_CMD=${FLUENTD_RUN_CMD:?}" >>${fluentd_data_path:?}/new-fluentd-docker-run-config.env
    echo "fluentd_config_checksum=$(md5sum ${fluentd_data_path:?}/etc/fluent.conf)" >>${fluentd_data_path:?}/new-fluentd-docker-run-config.env

    echo "  - Checking if config has changed since last run"
    if ! cmp -s "${fluentd_data_path:?}/new-fluentd-docker-run-config.env" "${fluentd_data_path:?}/current-fluentd-docker-run-config.env"; then
        echo "    - Fluentd container config has changed. Stopping up old fluentd container due to update."
        ${docker_cmd:?} stop --time 120 ${fluentd_continer_name} &>/dev/null || true
        ${docker_cmd:?} rm ${fluentd_continer_name} &>/dev/null || true
        mv -fv "${fluentd_data_path:?}/new-fluentd-docker-run-config.env" "${fluentd_data_path:?}/current-fluentd-docker-run-config.env"
    else
        echo "    - Fluentd container config has not changed."
    fi

    echo "  - Ensure fluentd container is running"
    if ! ${docker_cmd:?} ps | grep -q ${fluentd_continer_name}; then
        echo "    - Fetching latest fluentd image 'fluent/fluentd:${fluentd_image_tag:?}'"
        ${docker_cmd:?} pull fluent/fluentd:${fluentd_image_tag:?}
        echo

        echo "    - Creating fluentd container ---"
        ${docker_cmd:?} rm ${fluentd_continer_name} &>/dev/null || true
        ${FLUENTD_RUN_CMD:?}
        sleep 5 &
        wait $!
        echo
    else
        echo "    - The fluentd container already running ---"
    fi
else
    echo "  - No fluentd service required as the 'CUSTOM_LOG_DRIVER' env variable is configured as '${CUSTOM_LOG_DRIVER:-local}'"
    ${docker_cmd:?} stop --time 120 ${fluentd_continer_name} &>/dev/null || true
    ${docker_cmd:?} rm ${fluentd_continer_name} &>/dev/null || true
fi
