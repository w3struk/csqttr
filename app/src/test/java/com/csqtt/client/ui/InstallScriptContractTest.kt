package com.csqtt.client.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class InstallScriptContractTest {
    private fun script(): String {
        val candidates = listOf(
            File("../scripts/install.sh"),
            File("scripts/install.sh"),
        )
        return candidates.first(File::isFile).readText().replace("\r\n", "\n")
    }

    @Test
    fun `preflight performs working kernel probes`() {
        val deploy = script()
        assertTrue(deploy.contains("ip tuntap add dev \"\$probe_iface\" mode tun"))
        assertTrue(deploy.contains("setup_nat_and_firewall"))
        assertTrue(deploy.contains("iptables -w \"\$XT_WAIT\" -t nat -C POSTROUTING"))
        assertTrue(deploy.contains("probe_tun_support"))
        assertTrue(deploy.contains("prepare_candidate_release()"))
        assertTrue(deploy.contains("run_platform_preflight"))
    }

    @Test
    fun `installer accepts only amd64 server architecture aliases`() {
        val deploy = script()
        assertTrue(deploy.contains("require_runtime_tools() {"))
        val runtimeTools = deploy.substringAfter("require_runtime_tools() {").substringBefore("\n}\n")
        assertTrue(runtimeTools.isNotEmpty())
        assertFalse(runtimeTools.contains("detect_wan_interface"))
        assertTrue(runtimeTools.contains("x86_64|amd64"))
        assertTrue(runtimeTools.contains("Поддерживается только x86_64/amd64"))
        assertTrue(runtimeTools.contains("esac"))
        val archCase = runtimeTools.substringAfter("case \"\$(uname -m)\" in").substringBefore("esac")
        // Whitelist проверяется по факту: единственная принимающая ветка — пара
        // x86_64/amd64, всё остальное уходит в die. Литералы вида «aarch64|arm64»
        // в скрипте не встречаются, поэтому assertFalse по ним упасть не мог.
        assertEquals(
            "whitelist обязан принимать только x86_64/amd64, остальные архитектуры — отказ",
            listOf("x86_64|amd64", "*"),
            Regex("""^\s*(\S+)\)""", RegexOption.MULTILINE)
                .findAll(archCase)
                .map { it.groupValues[1] }
                .toList(),
        )
    }

    @Test
    fun `activation uses direct runtime paths and has no staged candidate`() {
        val deploy = script()
        assertTrue(deploy.contains("prepare_candidate_release()"))
        assertTrue(deploy.contains("install -m 0755 \"\$CANDIDATE_BINARY\" \"\${CSQTT_BIN_DIR}/csqtt\""))
        assertTrue(deploy.contains("install -m 0600 \"\$CANDIDATE_ENV_FILE\" \"\$CSQTT_ENV_FILE\""))
        assertTrue(deploy.contains("rm -f \"\${CSQTT_BIN_DIR}/csqtt\""))
        assertTrue(deploy.contains("rm -rf \"\$CSQTT_LIB_DIR\""))
        assertTrue(deploy.contains("clear_runtime_config_preserving_database()"))
        assertFalse(deploy.contains("csqtt.next.XXXXXX"))
        assertFalse(deploy.contains("csqtt-stage"))
        assertFalse(deploy.contains("verify_staged_release"))
        assertFalse(deploy.contains("CSQTT_DEPLOY_READY_FOR_UPLOAD"))
        assertTrue(deploy.contains("probe_tun_support"))
    }

    @Test
    fun `reserved runtime directories recover from a failed previous install`() {
        val deploy = script()
        assertTrue(deploy.contains("ensure_csqtt_directory()"))
        assertTrue(deploy.contains("rm -rf -- \"\$path\" || die \"Не удалось очистить путь CSQTT: \$path\""))
        assertTrue(deploy.contains("ensure_persistent_directory \"\$CSQTT_CONFIG_DIR\" 700"))
        assertTrue(deploy.contains("ensure_csqtt_directory \"\$CSQTT_LIB_DIR\" 755"))
        assertTrue(deploy.contains("setup_csqtt_environment() {\n    ensure_persistent_directory \"\$CSQTT_CONFIG_DIR\" 700"))
        assertTrue(deploy.contains("install -m 0600 \"\$CANDIDATE_ENV_FILE\" \"\$CSQTT_ENV_FILE\""))
    }

    @Test
    fun `redeploy removes old runtime config but preserves SQLite and its WAL files`() {
        val deploy = script()
        assertTrue(deploy.contains("readonly CSQTT_DATABASE_FILE=\"csqtt.db\""))
        assertTrue(deploy.contains("readonly CSQTT_DATABASE_WAL_FILE=\"csqtt.db-wal\""))
        assertTrue(deploy.contains("readonly CSQTT_DATABASE_SHM_FILE=\"csqtt.db-shm\""))
        assertTrue(deploy.contains("clear_runtime_config_preserving_database"))
        assertTrue(deploy.contains("\"\$CSQTT_DATABASE_FILE\"|\"\$CSQTT_DATABASE_WAL_FILE\"|\"\$CSQTT_DATABASE_SHM_FILE\"|passwords.json|passwords.json.imported|install.json|csqtt.db.pre-owner-migration|csqtt.db.pre-owner-migration-wal|csqtt.db.pre-owner-migration-shm|web_cert.pem|web_key.pem|letsencrypt-ip.env|letsencrypt.env|runtime-archive) continue"))
        assertFalse(deploy.contains("find \"\$CSQTT_CONFIG_DIR\" -mindepth 1 -maxdepth 1"))
    }

    @Test
    fun `docker uses minimal capabilities and repeats probes inside container`() {
        val deploy = script()
        assertTrue(deploy.contains("--cap-drop ALL"))
        assertTrue(deploy.contains("--cap-add NET_ADMIN"))
        assertTrue(deploy.contains("--cap-add NET_RAW"))
        assertTrue(deploy.contains("--device /dev/net/tun:/dev/net/tun"))
        assertTrue(deploy.contains("--security-opt seccomp=unconfined"))
        assertTrue(deploy.contains("probe_docker_runtime"))
        assertTrue(deploy.split("--cap-drop ALL").size >= 3)
        assertTrue(deploy.contains("COPY network-up.sh /usr/local/lib/csqtt/network-up.sh"))
        assertTrue(deploy.contains("exec /usr/local/bin/csqtt \\\"\$@\\\""))
        assertTrue(deploy.contains("write_network_helper \"\$context_dir/network-up.sh\""))
    }

    @Test
    fun `docker image build retries DNS with Yandex resolvers`() {
        val deploy = script()
        assertTrue(deploy.contains("DOCKER_BUILD_TIMEOUT_SECONDS"))
        assertTrue(deploy.contains("docker build --network host"))
        assertTrue(deploy.contains("CSQTT_BUILD_DNS_PRIMARY:-"))
        assertTrue(deploy.contains("FROM alpine:3.21"))
        assertTrue(deploy.contains("apk add --no-cache --no-progress ca-certificates iproute2 iptables"))
        assertTrue(deploy.contains("CSQTT_BUILD_DNS_PRIMARY=77.88.8.8"))
        assertTrue(deploy.contains("CSQTT_BUILD_DNS_SECONDARY=77.88.8.1"))
        assertTrue(deploy.contains("Temporary failure resolving|Could not resolve|Name or service not known"))
    }

    @Test
    fun `web health probe accepts the panel's unauthenticated response without creating sessions`() {
        val deploy = script()
        assertTrue(deploy.contains("200|301|302|401"))
        assertTrue(deploy.contains("${'$'}{scheme}://127.0.0.1:${'$'}{WEB_PORT}/"))
        assertFalse(deploy.contains("--data-binary @-"))
        assertFalse(deploy.contains("/api/login"))
        assertFalse(deploy.contains("NETWORK_READY_STAMP"))
    }

    @Test
    fun `configured network is verified after applying rules and after startup`() {
        val deploy = script()
        assertTrue(deploy.contains("verify_configured_network()"))
        assertTrue(deploy.split("verify_configured_network").size >= 4)
        assertTrue(deploy.contains("-j MASQUERADE >/dev/null 2>&1"))
        assertTrue(deploy.contains("-j TCPMSS --clamp-mss-to-pmtu 2>/dev/null"))
    }

    @Test
    fun `startup removes stale tunnel state and waits through the TUN initialization window`() {
        val deploy = script()
        assertTrue(deploy.contains("remove_csqtt_tun_interface()"))
        assertTrue(deploy.contains("timeout 2 ip link del \"\$CSQTT_IFACE\""))
        assertTrue(deploy.contains("write_tun_recovery_helper \"\${CSQTT_LIB_DIR}/tun-recover.sh\""))
        assertTrue(deploy.contains("ExecStartPre=\${CSQTT_LIB_DIR}/tun-recover.sh"))
        assertTrue(deploy.contains("release_owned_peer_port()"))
        assertTrue(deploy.contains("csqtt_process_is_owned()"))
        assertTrue(deploy.contains("""UDP/\${'$'}PEER_PORT runtime PID \${'$'}pid; terminating"""))
        assertTrue(deploy.contains("readonly START_STABILITY_SECONDS=\"\${CSQTT_START_STABILITY_SECONDS:-4}\""))
        assertTrue(deploy.contains("StartLimitIntervalSec=60"))
        assertTrue(deploy.contains("RestartSec=3"))
        assertTrue(deploy.contains("COPY tun-recover.sh /usr/local/lib/csqtt/tun-recover.sh"))
        assertTrue(deploy.contains("/usr/local/lib/csqtt/tun-recover.sh; exec /usr/local/bin/csqtt"))
    }

    @Test
    fun `runtime mode switch removes CSQTT paths and force releases the configured peer port`() {
        val deploy = script()
        assertTrue(deploy.contains("docker_container_runs_csqtt()"))
        assertTrue(deploy.contains("docker top \"\$container\" -eo pid,args"))
        assertTrue(deploy.contains("docker-\${container_id}.scope"))
        assertTrue(deploy.contains("remove_all_csqtt_docker_containers"))
        assertTrue(deploy.contains("stop_all_running_csqtt_systemd_units"))
        assertTrue(deploy.contains("remove_all_csqtt_systemd_units"))
        assertTrue(deploy.contains("assert_peer_port_is_available"))
        assertTrue(deploy.contains("force_release_peer_port"))
        assertFalse(
            "легаси-ремонт csqtp*-интерфейсов удалён вместе с переездом со старых установок",
            deploy.contains("cleanup_legacy_proxy_interfaces"),
        )
        assertTrue(deploy.contains("docker_container_for_pid"))
        assertTrue(deploy.contains("docker rm -f \"\$container\""))
        assertTrue(deploy.contains("--label com.csqtt.managed=true"))
        assertTrue(deploy.contains("archive_csqtt_docker_state()"))
        assertTrue(deploy.contains("CSQTT_RUNTIME_ARCHIVE_DIR"))
        assertTrue(deploy.contains("install.json|csqtt.db.pre-owner-migration"))
        assertTrue(deploy.contains("runtime-archive) continue"))
        assertTrue(deploy.contains("force_stop_csqtt_processes"))
        assertTrue(deploy.contains("all_csqtt_process_pids"))
        assertTrue(deploy.contains("csqtt_peer_port_is_owned"))
        assertTrue(deploy.contains("csqtt_process_owns_peer_port"))
        assertTrue(deploy.contains("readlink \"/proc/\$pid/exe\""))
        assertTrue(deploy.contains("--config-dir \${CSQTT_CONFIG_DIR}"))
        assertTrue(deploy.contains("kill -KILL \"\$pid\""))
        assertTrue(deploy.contains("kill -TERM \"\$pid\""))
        assertTrue(deploy.contains("принудительное освобождение"))
        assertFalse(deploy.contains("unknown runtime; refusing to alter it"))
        assertFalse(deploy.contains("CSQTT не будет их удалять"))
        assertFalse(deploy.contains("pkill -"))
        assertFalse(deploy.contains("pgrep -x csqtt"))
        assertFalse(deploy.contains("ipt_del_repeat"))
        assertFalse(deploy.contains("nft delete table ip csqtt"))
        assertFalse(deploy.contains("fw_add_input_tcp \"\$SSH_PORT\""))
        assertFalse(deploy.contains("--dport \"\$SSH_PORT\" -m comment --comment \"\$IPT_COMMENT\""))
    }

    @Test
    fun `runtime cleanup stops processes before deleting CSQTT runtime paths`() {
        val deploy = script()
        assertTrue(deploy.contains("csqtt_cleanup() {"))
        assertTrue(deploy.contains("setup_sysctl()"))
        assertTrue(deploy.contains("force_stop_csqtt_processes() {"))
        assertTrue(deploy.contains("force_release_peer_port()"))
        val cleanup = deploy.substringAfter("csqtt_cleanup() {").substringBefore("setup_sysctl()")
        val forceStop = deploy.substringAfter("force_stop_csqtt_processes() {")
            .substringBefore("force_release_peer_port()")

        assertTrue(forceStop.contains("kill -KILL \"\$pid\""))
        val stopIndex = cleanup.indexOf("force_stop_csqtt_processes")
        val removeIndex = cleanup.indexOf("rm -f \"\${CSQTT_BIN_DIR}/csqtt\"")
        assertTrue(stopIndex >= 0)
        assertTrue(removeIndex >= 0)
        assertTrue(
            "остановка процессов обязана идти до удаления бинарника",
            stopIndex < removeIndex,
        )
        assertTrue(cleanup.contains("systemctl daemon-reload || die \"systemctl daemon-reload завершился ошибкой после удаления старого runtime\""))
    }

    @Test
    fun `systemd runtime discovery and shutdown tolerate expected nonzero states`() {
        val deploy = script()
        assertTrue(deploy.contains("if systemd_unit_runs_csqtt \"\$unit\"; then"))
        assertFalse(deploy.contains("systemd_unit_runs_csqtt \"\$unit\" &&"))
        assertTrue(deploy.contains("systemctl list-units --type=service --all --no-legend --plain 2>/dev/null || true"))
        assertTrue(deploy.contains("systemctl list-unit-files --type=service --no-legend --plain 2>/dev/null || true"))
        assertTrue(deploy.contains("if ! timeout 10 systemctl stop \"\$unit\" >/dev/null 2>&1; then"))
        assertTrue(deploy.contains("systemctl is-active --quiet \"\$unit\"; then\n            die \"Не удалось остановить systemd runtime CSQTT: \$unit\""))
    }

    @Test
    fun `systemd service leaves resource limits to the VPS defaults`() {
        val deploy = script()
        assertFalse(deploy.contains("LimitNOFILE="))
        assertFalse(deploy.contains("LimitMEMLOCK="))
        assertFalse(deploy.contains("LimitNPROC="))
        assertFalse(deploy.contains("TasksMax="))
    }

    @Test
    fun `web panel prefers renewable trusted IP TLS with self signed fallback`() {
        val deploy = script()
        assertTrue(deploy.contains("--preferred-profile shortlived"))
        assertTrue(deploy.contains("--ip-address \"\$public_ip\""))
        assertTrue(deploy.contains("--force-renewal"))
        assertTrue(deploy.contains("openssl x509 -noout -checkend \"\$LE_RENEW_BEFORE_SECONDS\""))
        assertTrue(deploy.contains("OnUnitInactiveSec=24h") || deploy.contains("OnUnitInactiveSec=1h"))
        assertTrue(deploy.contains("fw_add_input_tcp \"\$LE_HTTP_PORT\""))
        assertTrue(deploy.contains("web_cert.pem|web_key.pem|letsencrypt-ip.env|letsencrypt.env|runtime-archive"))
        assertTrue(deploy.contains("systemctl kill --kill-who=main --signal USR1 csqtt"))
        assertTrue(deploy.contains("docker kill --signal USR1 csqtt"))
        assertTrue(deploy.contains("issuer=\"\${issuer#issuer=}\""))
        assertTrue(deploy.contains("subject=\"\${subject#subject=}\""))
        assertTrue(deploy.contains("! python3 -c 'import ensurepip'"))
        assertTrue(deploy.contains("apt) python_packages=(python3 python3-venv)"))
        assertTrue(deploy.contains("pkg_install_with_refresh()"))
        assertTrue(deploy.contains("pkg_install_with_refresh \"\${python_packages[@]}\""))
        assertTrue(deploy.contains("local ip=\"\$1\" first second third fourth value"))
        assertTrue(deploy.contains("self-signed fallback"))
    }

    @Test
    fun `certificate ownership keeps user TLS untouched and renews only CSQTT certificates`() {
        val deploy = script()
        assertTrue(deploy.contains("certificate_is_csqtt_rcgen()"))
        assertTrue(deploy.contains("certificate_is_csqtt_letsencrypt()"))
        assertTrue(deploy.contains("web_certificate_is_csqtt_managed()"))
        assertTrue(deploy.contains("web_certificate_is_user_managed()"))
        assertTrue(deploy.contains("CN=rcgen self signed cert"))
        assertTrue(deploy.contains("O=Let's Encrypt"))
        assertTrue(deploy.contains("IP Address:\${identifier}"))
        assertTrue(deploy.contains("DNS:\${identifier}"))
        assertTrue(deploy.contains("rm -f -- \"\$CSQTT_LE_STATE_FILE\""))
        assertTrue(deploy.contains("disable_letsencrypt_renewal_timer"))
        assertTrue(deploy.contains("CSQTT не изменяет его и отключает собственное продление"))
    }

    @Test
    fun `panel mode is resolved before the client web port is validated`() {
        val deploy = script()
        assertTrue(deploy.contains("install_main() {"))
        val installBranch = deploy.substringAfter("install_main() {")
        val resolve = installBranch.indexOf("resolve_panel_mode")
        val validatePort = installBranch.indexOf("validate_port \"CSQTT_WEB_PORT\"")
        assertTrue(resolve >= 0)
        assertTrue(validatePort >= 0)
        assertTrue(
            "resolve_panel_mode обязан идти до validate_port: иначе доменный режим падает на порту клиента",
            resolve < validatePort,
        )
    }

    @Test
    fun `panel web port is checked before the runtime tries to bind it`() {
        val deploy = script()
        assertTrue(deploy.contains("install_main() {"))
        val installBranch = deploy.substringAfter("install_main() {")
        val check = installBranch.indexOf("assert_web_port_is_available")
        val dockerStart = installBranch.indexOf("run_timed \"Docker activation\" setup_csqtt_docker")
        val start = installBranch.indexOf("run_timed \"запуск\" start_csqtt")
        assertTrue(check >= 0)
        assertTrue(dockerStart >= 0)
        assertTrue(start >= 0)
        assertTrue(
            "проверка порта обязана идти до setup_csqtt_docker: иначе занятый 443 даёт невнятный crash-loop",
            check < dockerStart,
        )
        assertTrue(
            "проверка порта обязана идти до запуска панели",
            check < start,
        )
    }

    @Test
    fun `installer issues and renews a trusted certificate for a domain panel`() {
        val deploy = script()
        assertTrue(deploy.contains("resolve_panel_mode"))
        assertTrue(deploy.contains("PANEL_MODE=\"domain\""))
        assertTrue(deploy.contains("--domains \"\$PANEL_HOST\""))
        assertTrue(deploy.contains("fw_remove_input_tcp"))
        assertTrue(deploy.contains("ensure_persistent_directory"))
        assertTrue(deploy.contains("--cap-add NET_BIND_SERVICE"))
        assertTrue(deploy.contains("setup_web_panel_tls"))
        assertTrue(deploy.contains("LE_ROOT=\"\${CSQTT_LE_ROOT:-/etc/letsencrypt}\""))
        assertFalse(deploy.contains("setup_letsencrypt_ip_tls"))
    }

    @Test
    fun `domain preflight guards the running panel before the cutover`() {
        val deploy = script()
        assertTrue(deploy.contains("install_main() {"))
        val installBranch = deploy.substringAfter("install_main() {")
        val preflight = installBranch.indexOf("run_domain_mode_preflight")
        val cleanup = installBranch.indexOf("run_timed \"переключение runtime\" csqtt_cleanup")
        assertTrue(preflight >= 0)
        assertTrue(cleanup >= 0)
        assertTrue(
            "проверки доменного режима обязаны идти до остановки работающей панели",
            preflight < cleanup,
        )
        assertTrue(deploy.contains("assert_letsencrypt_http_port_is_available"))
        assertTrue(deploy.contains("assert_web_port_is_available"))
    }

    @Test
    fun `certificate state records the panel mode and is written last`() {
        val deploy = script()
        assertTrue(deploy.contains("printf 'MODE=%s\\nIDENTIFIER=%s\\nCERT_NAME=%s\\n'"))
        assertTrue(deploy.contains("letsencrypt.env"))
        assertTrue(deploy.contains("csqtt-ip-%s"))
        assertTrue(deploy.contains("csqtt-%s"))
        assertTrue(deploy.contains("--domains"))
        assertTrue(deploy.contains("--ip-address \"\$public_ip\""))
        assertTrue(deploy.contains("stop_letsencrypt_renewal_timer"))
        assertTrue(deploy.contains("Environment=CSQTT_LE_ROOT=\${CSQTT_LE_ROOT}"))
        assertTrue(deploy.contains("Environment=CSQTT_LE_IDENTIFIER="))
    }
}
