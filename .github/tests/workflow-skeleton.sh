#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Статические проверки скелета workflow'ов CI: release.yml (релиз по тегу),
# build.yml (reusable-сборка, которую вызывают релиз и бета) и beta.yml
# (пуш в main -> сборка -> Telegram).
#
# Проверяется только то, что можно проверить без запуска раннера:
#   * YAML парсится, триггеры и permissions разнесены между workflow и job;
#   * concurrency релиза — константная группа;
#   * release.yml состоит из трёх job'ов (resolve -> build -> publish): build
#     вызывает build.yml с ref из needs.resolve.outputs.commit, publish
#     публикует через needs.*; гейтов и сборки в файле нет;
#   * в теле publish нет подстановок шагов resolve/старта/подписи — после
#     переноса это job'ы, а не шаги;
#   * каждый `needs.<job>.outputs.<name>` объявлен у job'а (у вызывающего
#     reusable workflow — в on.workflow_call.outputs build.yml);
#   * все `uses:` запинены полным 40-символьным SHA;
#   * `secrets.*` — только пять заведённых имён keystore/подписи, явным
#     списком (не inherit);
#   * каждый `run:` начинается с `set -euo pipefail`;
#   * вызванные `bash .github/scripts/<name>.sh` существуют и исполняемы;
#   * build.yml: тулчейн (Free disk space -> SDK -> Rust -> Zig -> cargo-*)
#     и гейты (локап -> Kotlin -> Rust client -> Rust server musl) идут
#     в фиксированном порядке, шаги подписи/сборки/сверки — после гейтов;
#   * версии cargo-ndk/cargo-zigbuild запинены в шаге установки и входят
#     в ключ кеша `Cache Cargo binaries`;
#   * `Cleanup keystore` выполняется всегда, `Dry run`/`Publish release`
#     разведены строгими сравнениями `== 'true'` / `== 'false'`;
#   * APK не передаются в сверку глобом (`--apk` со звёздочкой);
#   * beta.yml: push в main и workflow_dispatch, нет `concurrency` (иначе
#     queue: single отменял бы ожидающий прогон) и нет `contents: write`;
#     версия -> build.yml с version-name/expected-version-code/abis ->
#     Telegram; секретов ровно пять keystore плюс два TELEGRAM_*.
#
# Файл, на который workflow ссылается, обязан существовать и быть исполняемым:
# контракт репозитория требует +x, а «ещё не написан» больше не аргумент —
# все шесть helper-скриптов лежат в репозитории.
#
# Пишет только во временные каталоги (ничего не пишет вовсе — только читает).
# exit 0 — успех, иначе сообщение в stderr.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/release.yml"
BUILD="$REPO_ROOT/.github/workflows/build.yml"
BETA="$REPO_ROOT/.github/workflows/beta.yml"

if [[ ! -f "$WORKFLOW" ]]; then
    printf 'workflow-skeleton: нет файла %s\n' "$WORKFLOW" >&2
    exit 1
fi

if [[ ! -f "$BUILD" ]]; then
    printf 'workflow-skeleton: нет файла %s\n' "$BUILD" >&2
    exit 1
fi

if [[ ! -f "$BETA" ]]; then
    printf 'workflow-skeleton: нет файла %s\n' "$BETA" >&2
    exit 1
fi

python3 - "$WORKFLOW" "$BUILD" <<'PY'
import re
import sys

import yaml

release_path, build_path = sys.argv[1], sys.argv[2]


def die(message):
    sys.stderr.write("workflow-skeleton: %s\n" % message)
    raise SystemExit(1)


def want(condition, message):
    if not condition:
        die(message)


def load(path):
    with open(path, encoding="utf-8") as fh:
        source = fh.read()
    try:
        document = yaml.safe_load(source)
    except yaml.YAMLError as exc:
        die("%s: YAML не парсится: %s" % (path, exc))
    want(isinstance(document, dict), "%s: верхний уровень — не mapping" % path)
    return document, source


def call_section(document, label):
    # PyYAML читает `on` по правилам YAML 1.1 и превращает его в булев True —
    # это ожидаемо, файл под это подгонять не нужно.
    triggers = document.get("on") if "on" in document else document.get(True)
    want(isinstance(triggers, dict), "%s: нет блока триггеров 'on'" % label)
    call = triggers.get("workflow_call")
    want(isinstance(call, dict), "%s: нет workflow_call" % label)
    return call


def needs_list(job):
    needs = job.get("needs")
    if needs is None:
        return []
    if isinstance(needs, str):
        return [needs]
    want(isinstance(needs, list), "needs должен быть строкой или списком")
    return needs


doc, release_text = load(release_path)
build_doc, build_text = load(build_path)

want(
    doc.get("name") == "Release",
    "name должен быть 'Release', получено %r" % (doc.get("name"),),
)

triggers = doc.get("on") if "on" in doc else doc.get(True)
want(isinstance(triggers, dict), "блок триггеров 'on' — не mapping")

push = triggers.get("push")
want(isinstance(push, dict), "нет триггера push")
want(
    push.get("tags") == ["v*"],
    "push.tags должен быть ['v*'], получено %r" % (push.get("tags"),),
)

dispatch = triggers.get("workflow_dispatch")
want(isinstance(dispatch, dict), "нет триггера workflow_dispatch")
inputs = dispatch.get("inputs")
want(isinstance(inputs, dict), "нет workflow_dispatch.inputs")

tag_name = inputs.get("tag_name")
want(isinstance(tag_name, dict), "нет входа workflow_dispatch.inputs.tag_name")
want(
    tag_name.get("required") is True,
    "tag_name.required должен быть true, получено %r" % (tag_name.get("required"),),
)
want(
    tag_name.get("type") == "string",
    "tag_name.type должен быть 'string', получено %r" % (tag_name.get("type"),),
)

dry_run = inputs.get("dry_run")
want(isinstance(dry_run, dict), "нет входа workflow_dispatch.inputs.dry_run")
want(
    dry_run.get("required") is False,
    "dry_run.required должен быть false, получено %r" % (dry_run.get("required"),),
)
want(
    dry_run.get("type") == "boolean",
    "dry_run.type должен быть 'boolean', получено %r" % (dry_run.get("type"),),
)
want(
    dry_run.get("default") is False,
    "dry_run.default должен быть false, получено %r" % (dry_run.get("default"),),
)

want(
    doc.get("permissions") == {"contents": "read"},
    "permissions уровня workflow должны быть {contents: read}, получено %r"
    % (doc.get("permissions"),),
)

concurrency = doc.get("concurrency")
want(isinstance(concurrency, dict), "нет блока concurrency")
want(
    concurrency.get("group") == "release",
    "concurrency.group должен быть 'release' (константа, не github.ref), получено %r"
    % (concurrency.get("group"),),
)
want(
    concurrency.get("cancel-in-progress") is False,
    "concurrency.cancel-in-progress должен быть false, получено %r"
    % (concurrency.get("cancel-in-progress"),),
)

jobs = doc.get("jobs")
want(isinstance(jobs, dict), "нет блока jobs")
want(
    set(jobs) == {"resolve", "build", "publish"},
    "jobs обязаны быть ровно {resolve, build, publish}, получено %r"
    % (sorted(jobs),),
)

# --- resolve -----------------------------------------------------------------
resolve_job = jobs["resolve"]
want(isinstance(resolve_job, dict), "job resolve — не mapping")
want(
    resolve_job.get("runs-on") == "ubuntu-24.04",
    "resolve.runs-on должен быть 'ubuntu-24.04', получено %r"
    % (resolve_job.get("runs-on"),),
)
want(
    resolve_job.get("timeout-minutes") == 20,
    "resolve.timeout-minutes должен быть 20, получено %r"
    % (resolve_job.get("timeout-minutes"),),
)
want(
    resolve_job.get("permissions") == {"contents": "read"},
    "permissions job'а resolve должны быть {contents: read}, получено %r"
    % (resolve_job.get("permissions"),),
)

RESOLVE_OUTPUTS = {
    "tag": "tag",
    "version": "version",
    "commit": "commit",
    "dry_run": "dry_run",
    "started": "started",
}
resolve_outputs = resolve_job.get("outputs")
want(isinstance(resolve_outputs, dict), "у job'а resolve нет outputs")
want(
    set(resolve_outputs) == set(RESOLVE_OUTPUTS),
    "outputs resolve обязаны быть %r, получено %r"
    % (sorted(RESOLVE_OUTPUTS), sorted(resolve_outputs)),
)
step_output_ref = re.compile(r"^\$\{\{ steps\.([a-z0-9_-]+)\.outputs\.([a-z0-9_-]+) \}\}$")
for name in sorted(RESOLVE_OUTPUTS):
    match = step_output_ref.match(str(resolve_outputs[name]))
    want(
        match is not None,
        "resolve.outputs.%s обязан ссылаться на steps.<id>.outputs.<name>, получено %r"
        % (name, resolve_outputs.get(name)),
    )
    want(
        match.group(2) == RESOLVE_OUTPUTS[name],
        "resolve.outputs.%s должен читать одноимённый выход шага, получено %r"
        % (name, match.group(2)),
    )

resolve_steps = resolve_job.get("steps")
want(isinstance(resolve_steps, list) and resolve_steps, "у job'а resolve нет шагов")
resolve_ids = [step["id"] for step in resolve_steps if "id" in step]
want(
    resolve_ids == ["start", "resolve"],
    "шаги с id: в resolve обязаны быть ['start', 'resolve'], получено %r"
    % (resolve_ids,),
)
for output_name in ("tag", "version", "commit", "dry_run", "started"):
    producer = step_output_ref.match(str(resolve_outputs[output_name])).group(1)
    want(
        producer in resolve_ids,
        "resolve.outputs.%s читает steps.%s.outputs.*, но шага с id: %s нет"
        % (output_name, producer, producer),
    )

resolve_by_name = {step.get("name"): step for step in resolve_steps}
checkout = resolve_by_name.get("Checkout")
want(checkout is not None, "в resolve нет шага 'Checkout'")
checkout_with = checkout.get("with") or {}
want(
    checkout_with.get("fetch-depth") == 0,
    "Checkout в resolve обязан брать полную историю (fetch-depth: 0), получено %r"
    % (checkout_with.get("fetch-depth"),),
)
want(
    checkout_with.get("persist-credentials") is False,
    "Checkout в resolve обязан ставить persist-credentials: false",
)
want(
    "Setup Python" in resolve_by_name,
    "в resolve должен остаться шаг 'Setup Python'",
)

start_step = resolve_by_name.get("Record start time")
want(start_step is not None, "в resolve нет шага 'Record start time'")
want(start_step.get("id") == "start", "у 'Record start time' должен быть id: start")

resolve_step = resolve_by_name.get("Resolve release target")
want(resolve_step is not None, "в resolve нет шага 'Resolve release target'")
want(resolve_step.get("id") == "resolve", "у 'Resolve release target' должен быть id: resolve")
resolve_env = resolve_step.get("env") or {}
want(
    "INPUT_TAG_NAME" in resolve_env,
    "у 'Resolve release target' должен быть env.INPUT_TAG_NAME (${{ inputs.tag_name }})",
)
want(
    "inputs.tag_name" in str(resolve_env.get("INPUT_TAG_NAME", "")),
    "env.INPUT_TAG_NAME обязан ссылаться на inputs.tag_name, а не быть литералом",
)
want(
    "INPUT_DRY_RUN" in resolve_env,
    "у 'Resolve release target' должен быть env.INPUT_DRY_RUN (${{ inputs.dry_run }})",
)
want(
    "inputs.dry_run" in str(resolve_env.get("INPUT_DRY_RUN", "")),
    "env.INPUT_DRY_RUN обязан ссылаться на inputs.dry_run, а не быть литералом",
)
want(
    "resolve-release-target.sh" in str(resolve_step.get("run", "")),
    "'Resolve release target' обязан вызывать .github/scripts/resolve-release-target.sh",
)

# --- build (reusable workflow) -----------------------------------------------
build_job = jobs["build"]
want(isinstance(build_job, dict), "job build — не mapping")
want(
    needs_list(build_job) == ["resolve"],
    "build.needs обязан быть resolve, получено %r" % (build_job.get("needs"),),
)
want(
    build_job.get("uses") == "./.github/workflows/build.yml",
    "build.uses обязан быть './.github/workflows/build.yml', получено %r"
    % (build_job.get("uses"),),
)
for forbidden_key in ("runs-on", "timeout-minutes"):
    want(
        forbidden_key not in build_job,
        "у job'а build не должно быть %r: он вызывает reusable workflow" % forbidden_key,
    )
want(
    build_job.get("permissions") == {"contents": "read"},
    "permissions job'а build должны быть {contents: read}, получено %r"
    % (build_job.get("permissions"),),
)
build_with = build_job.get("with") or {}
want(isinstance(build_with, dict), "у build нет with")
want(
    "needs.resolve.outputs.commit" in str(build_with.get("ref", "")),
    "build.with.ref обязан брать needs.resolve.outputs.commit, получено %r"
    % (build_with.get("ref"),),
)
want(
    build_with.get("abis") == "arm64-v8a,armeabi-v7a,x86_64",
    "build.with.abis обязан быть 'arm64-v8a,armeabi-v7a,x86_64', получено %r"
    % (build_with.get("abis"),),
)
for not_passed in ("version-name", "expected-version-code"):
    want(
        not_passed not in build_with,
        "релиз не передаёт %r: версия читается из app/build.gradle.kts" % not_passed,
    )

ALLOWED_SECRETS = {
    "ANDROID_KEYSTORE_BASE64",
    "ANDROID_KEYSTORE_PASSWORD",
    "ANDROID_KEY_ALIAS",
    "ANDROID_KEY_PASSWORD",
    "ANDROID_KEYSTORE_FINGERPRINT",
}
build_secrets = build_job.get("secrets") or {}
want(isinstance(build_secrets, dict), "у build нет secrets")
want(
    set(build_secrets) == ALLOWED_SECRETS,
    "build.secrets обязан перечислять ровно пять ANDROID_KEYSTORE_*, получено %r"
    % (sorted(build_secrets),),
)
for secret_name in sorted(build_secrets):
    want(
        build_secrets[secret_name] == "${{ secrets.%s }}" % secret_name,
        "build.secrets.%s обязан быть ${{ secrets.%s }}, получено %r"
        % (secret_name, secret_name, build_secrets[secret_name]),
    )

# --- publish -----------------------------------------------------------------
publish_job = jobs["publish"]
want(isinstance(publish_job, dict), "job publish — не mapping")
publish_needs = needs_list(publish_job)
for required in ("resolve", "build"):
    want(
        required in publish_needs,
        "publish.needs обязан содержать %r, получено %r" % (required, publish_needs),
    )
want(
    publish_job.get("permissions") == {"contents": "write"},
    "permissions job'а publish должны быть {contents: write}, получено %r"
    % (publish_job.get("permissions"),),
)
want(
    publish_job.get("runs-on") == "ubuntu-24.04",
    "publish.runs-on должен быть 'ubuntu-24.04', получено %r"
    % (publish_job.get("runs-on"),),
)
want(
    isinstance(publish_job.get("timeout-minutes"), int),
    "publish.timeout-minutes должен быть целым числом, получено %r"
    % (publish_job.get("timeout-minutes"),),
)

publish_steps = publish_job.get("steps")
want(isinstance(publish_steps, list) and publish_steps, "у job'а publish нет шагов")
publish_names = [step.get("name") for step in publish_steps]
publish_by_name = {step.get("name"): step for step in publish_steps}

# Негативная проверка из ревью: после переноса resolve/сборка — это job'ы,
# а не шаги. Дословно перенесённые подстановки стали бы пустыми и дали бы
# зелёный прогон без релиза, поэтому в теле publish этих подстрок быть не может.
publish_match = re.search(r"(?ms)^  publish:\n(.+)\Z", release_text)
want(publish_match is not None, "не удалось выделить текст job'а publish")
publish_text = publish_match.group(1)
for stale in ("steps.resolve", "steps.start", "steps.signcheck"):
    want(
        stale not in publish_text,
        "в job'е publish осталась подстановка %r: нужна needs.<job>.outputs.*" % stale,
    )

download = publish_by_name.get("Download build artifact")
want(download is not None, "в publish нет шага 'Download build artifact'")
pinned = re.compile(r"^[^@]+@[0-9a-f]{40}$")
want(
    pinned.match(str(download.get("uses", ""))) is not None,
    "'Download build artifact' не запинен на 40-символьный SHA: %r"
    % (download.get("uses"),),
)
download_with = download.get("with") or {}
want(
    download_with.get("name") == "${{ needs.build.outputs.artifact-name }}",
    "'Download build artifact'.name обязан быть needs.build.outputs.artifact-name, получено %r"
    % (download_with.get("name"),),
)
want(
    download_with.get("path") == "${{ runner.temp }}/build-output",
    "'Download build artifact'.path обязан быть ${{ runner.temp }}/build-output, получено %r"
    % (download_with.get("path"),),
)

collect = publish_by_name.get("Collect release assets")
want(collect is not None, "в publish нет шага 'Collect release assets'")
collect_run = str(collect.get("run", ""))
for fragment in (
    "collect-release-assets.sh",
    '--apk-dir "$RUNNER_TEMP/build-output/apk"',
    '--assets-dir "$RUNNER_TEMP/build-output/assets"',
    '--version "${{ needs.build.outputs.version }}"',
):
    want(
        fragment in collect_run,
        "'Collect release assets' обязан содержать %r, получено:\n%s"
        % (fragment, collect_run),
    )

target = publish_by_name.get("Checkout release target")
want(target is not None, "в publish нет шага 'Checkout release target'")
want(target.get("id") == "target", "у 'Checkout release target' должен быть id: target")
target_run = str(target.get("run", ""))
want(
    "git checkout --detach" in target_run
    and "needs.resolve.outputs.commit" in target_run,
    "'Checkout release target' обязан делать git checkout --detach по "
    "needs.resolve.outputs.commit, получено:\n%s" % target_run,
)

note = publish_by_name.get("Generate release note")
want(note is not None, "в publish нет шага 'Generate release note'")
note_run = str(note.get("run", ""))
for fragment in (
    "release-note.sh",
    '--tag "${{ needs.resolve.outputs.tag }}"',
    "--duration-seconds",
    "needs.resolve.outputs.started",
    '--fingerprint "${{ needs.build.outputs.fingerprint }}"',
    '--signer "${{ needs.build.outputs.signer-cn }}"',
):
    want(
        fragment in note_run,
        "'Generate release note' обязан содержать %r, получено:\n%s"
        % (fragment, note_run),
    )

dry = publish_by_name.get("Dry run: draft and discard")
publish = publish_by_name.get("Publish release")
want(dry is not None, "в publish нет шага 'Dry run: draft and discard'")
want(publish is not None, "в publish нет шага 'Publish release'")

# 2. dry_run разводится строгими сравнениями: при опечатке в имени выхода
#    значение пустое, и `!= 'true'` опубликовал бы в dry-run.
dry_if = str(dry.get("if", ""))
publish_if = str(publish.get("if", ""))
want(
    re.search(r"needs\.resolve\.outputs\.dry_run\s*==\s*'true'", dry_if),
    "у 'Dry run: draft and discard' должен быть if с "
    "needs.resolve.outputs.dry_run == 'true', получено %r" % (dry_if,),
)
want(
    re.search(r"needs\.resolve\.outputs\.dry_run\s*==\s*'false'", publish_if),
    "у 'Publish release' должен быть if с "
    "needs.resolve.outputs.dry_run == 'false', получено %r" % (publish_if,),
)
want(
    "!=" not in publish_if,
    "условие 'Publish release' не должно строиться на !=: получено %r" % (publish_if,),
)

dry_run_code = "\n".join(
    line for line in str(dry.get("run", "")).splitlines() if not line.lstrip().startswith("#")
)
publish_run_code = "\n".join(
    line
    for line in str(publish.get("run", "")).splitlines()
    if not line.lstrip().startswith("#")
)
want(
    "--dry-run" in dry_run_code,
    "'Dry run: draft and discard' обязан вызывать publish-release.sh с --dry-run",
)
want(
    "--dry-run" not in publish_run_code,
    "'Publish release' не должен передавать --dry-run",
)
for step_name, code in (
    ("Dry run: draft and discard", dry_run_code),
    ("Publish release", publish_run_code),
):
    want(
        "publish-release.sh" in code,
        "%r обязан публиковать через .github/scripts/publish-release.sh" % step_name,
    )
    want(
        '--asset "${ASSETS[@]}"' not in code,
        "%r передаёт ассеты одним --asset: нужен повторяемый --asset в цикле"
        % step_name,
    )
    want(
        'asset_args+=(--asset "$asset")' in code,
        "%r обязан собирать повторяемые --asset циклом" % step_name,
    )
    want(
        "asset-paths.txt" in code,
        "%r обязан читать список ассетов из asset-paths.txt" % step_name,
    )

# GH_TOKEN берётся из github.token, а не из секрета: allowlist не расширяется.
for step_name in ("Dry run: draft and discard", "Publish release"):
    env = publish_by_name[step_name].get("env") or {}
    want(
        env.get("GH_TOKEN") == "${{ github.token }}",
        "%r обязан брать GH_TOKEN из ${{ github.token }}, получено %r"
        % (step_name, env.get("GH_TOKEN")),
    )
want(
    "secrets.GITHUB_TOKEN" not in release_text,
    "GH_TOKEN берётся из ${{ github.token }}, а не из secrets.GITHUB_TOKEN",
)

# --- релиз больше не собирает и не гоняет гейты ------------------------------
all_step_names = [
    step.get("name")
    for job in jobs.values()
    for step in (job.get("steps") or [])
]
BUILD_ONLY_STEPS = (
    "Restore keystore",
    "Build release APKs",
    "Verify native provenance",
    "Stage build outputs",
    "Verify APK signatures",
    "Verify APK identity",
    "Upload artifacts",
    "Cleanup keystore",
)
for name in BUILD_ONLY_STEPS:
    want(
        name not in all_step_names,
        "release.yml не должен содержать шаг %r — он живёт в build.yml" % (name,),
    )
want(
    not any(str(name).startswith("Gate: ") for name in all_step_names),
    "в release.yml не должно быть гейтов: они живут в build.yml",
)
want(
    "assembleRelease" not in release_text,
    "в release.yml не должно быть сборки (assembleRelease): она живёт в build.yml",
)
for once in (
    "Collect release assets",
    "Generate release note",
    "Dry run: draft and discard",
    "Publish release",
):
    want(
        all_step_names.count(once) == 1,
        "шаг %r обязан встречаться в release.yml ровно один раз, получено %d"
        % (once, all_step_names.count(once)),
    )

# --- контракт вызова build.yml ----------------------------------------------
build_call = call_section(build_doc, "build.yml")
declared_inputs = set((build_call.get("inputs") or {}).keys())
declared_secrets = set((build_call.get("secrets") or {}).keys())
declared_outputs = set((build_call.get("outputs") or {}).keys())
want(
    set(build_with) <= declared_inputs,
    "release.yml передаёт необъявленный вход build.yml: %r"
    % (sorted(set(build_with) - declared_inputs),),
)
want(
    set(build_secrets) <= declared_secrets,
    "release.yml передаёт необъявленный секрет build.yml: %r"
    % (sorted(set(build_secrets) - declared_secrets),),
)
consumed_build_outputs = set(
    re.findall(r"needs\.build\.outputs\.([a-z0-9_-]+)", release_text)
)
want(
    consumed_build_outputs <= declared_outputs,
    "release.yml читает необъявленный выход build.yml: %r"
    % (sorted(consumed_build_outputs - declared_outputs),),
)

# --- производители и потребители выходов job'ов ------------------------------
step_output_refs = re.compile(r"steps\.([A-Za-z0-9_-]+)\.outputs\.")
declared_job_outputs = {}
for job_id, job in jobs.items():
    outputs = job.get("outputs") or {}
    if outputs:
        want(isinstance(outputs, dict), "outputs job'а %s — не mapping" % job_id)
    step_ids = {step.get("id") for step in (job.get("steps") or []) if "id" in step}
    for output_name, value in (outputs or {}).items():
        producers = step_output_refs.findall(str(value))
        want(
            producers,
            "job %s: outputs.%s не ссылается на steps.<id>.outputs.* (%r)"
            % (job_id, output_name, value),
        )
        for producer in producers:
            want(
                producer in step_ids,
                "job %s: outputs.%s читает steps.%s.outputs.*, но шага с id: %s нет"
                % (job_id, output_name, producer, producer),
            )
    declared_job_outputs[job_id] = set((outputs or {}).keys())

for job_id in sorted(jobs):
    for source, output_name in re.findall(
        r"needs\.([a-z0-9_-]+)\.outputs\.([a-z0-9_-]+)", release_text
    ):
        want(
            source in jobs,
            "job %s читает needs.%s.outputs.*, но такого job'а нет" % (job_id, source),
        )
        # У job'а, вызывающего reusable workflow, outputs объявлены не в
        # jobs.<job>.outputs, а в on.workflow_call.outputs build.yml; их
        # проверяет межфайловый контракт выше.
        if "uses" in jobs[source]:
            continue
        want(
            output_name in declared_job_outputs[source],
            "job %s читает needs.%s.outputs.%s, но выход не объявлен в jobs.%s.outputs"
            % (job_id, source, output_name, source),
        )

# --- общие инварианты для release.yml и build.yml ---------------------------
for label, source, document in (
    ("release.yml", release_text, doc),
    ("build.yml", build_text, build_doc),
):
    want("inherit" not in source, "%s: секреты передаются явным списком, не inherit" % label)

    referenced_secrets = set(re.findall(r"secrets\.([A-Za-z0-9_]+)", source))
    want(referenced_secrets, "%s: workflow не ссылается ни на один секрет" % label)
    unexpected = referenced_secrets - ALLOWED_SECRETS
    want(
        not unexpected,
        "%s: недопустимые секреты: %r (разрешены только %r)"
        % (label, sorted(unexpected), sorted(ALLOWED_SECRETS)),
    )
    want(
        "TELEGRAM_" not in source,
        "%s: TELEGRAM_* секреты живут только в beta.yml" % label,
    )
    want(
        re.search(r"^[ \t]*set[ \t]+-[a-z]*x", source, re.M) is None,
        "%s: `set -x` запрещён" % label,
    )

    for job_id, job in (document.get("jobs") or {}).items():
        steps = job.get("steps") or []
        for step in steps:
            if "uses" in step:
                value = str(step["uses"])
                want(
                    value == "./.github/workflows/build.yml"
                    or pinned.match(value) is not None,
                    "%s: экшен не запинен на 40-символьный SHA: %r"
                    % (label, value),
                )
            if "run" not in step:
                continue
            run = str(step["run"])
            lines = [line for line in run.splitlines() if line.strip()]
            want(
                bool(lines) and lines[0].strip() == "set -euo pipefail",
                "%s: run-блок шага %r не начинается с 'set -euo pipefail'"
                % (label, step.get("name") or step.get("id") or "?"),
            )
            match = re.search(r"--apk[=\s]+\S*\*", run)
            want(
                match is None,
                "%s: шаг %r передаёт APK в --apk глобом: %r — нужен цикл "
                "с отдельным --apk"
                % (label, step.get("name"), match.group(0) if match else ""),
            )

print("RELEASE OK")
PY

# 10. build.yml — reusable workflow сборки: контракт вызова и перенос шагов.
python3 - "$BUILD" <<'PY'
import re
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as fh:
    text = fh.read()


def die(message):
    sys.stderr.write("workflow-skeleton: build.yml: %s\n" % message)
    raise SystemExit(1)


def want(condition, message):
    if not condition:
        die(message)


try:
    doc = yaml.safe_load(text)
except yaml.YAMLError as exc:
    die("YAML не парсится: %s" % exc)

want(isinstance(doc, dict), "верхний уровень workflow — не mapping")
want(
    doc.get("name") == "Build",
    "name должен быть 'Build', получено %r" % (doc.get("name"),),
)

if "on" in doc:
    triggers = doc["on"]
elif True in doc:
    triggers = doc[True]
else:
    die("нет блока триггеров 'on'")
want(isinstance(triggers, dict), "блок триггеров 'on' — не mapping")
want(
    set(triggers) == {"workflow_call"},
    "триггером обязан быть только workflow_call, получено %r" % (sorted(triggers),),
)
call = triggers["workflow_call"]
want(isinstance(call, dict), "workflow_call — не mapping")

# 10.1 Контракт вызова: входы.
inputs = call.get("inputs")
want(isinstance(inputs, dict), "нет workflow_call.inputs")
want(
    set(inputs) == {"ref", "version-name", "abis", "expected-version-code"},
    "inputs обязаны быть ровно {ref, version-name, abis, expected-version-code}, получено %r"
    % (sorted(inputs),),
)
for input_name in sorted(inputs):
    spec = inputs[input_name]
    want(isinstance(spec, dict), "input %r — не mapping" % (input_name,))
    want(
        spec.get("type") == "string",
        "input %r: type должен быть 'string', получено %r"
        % (input_name, spec.get("type")),
    )
want(
    inputs["ref"].get("required") is True,
    "input 'ref' обязан быть required: true, получено %r"
    % (inputs["ref"].get("required"),),
)
want(
    str(inputs["abis"].get("default", "")).strip() != "",
    "у input 'abis' должен быть непустой default",
)

# 10.2 Секреты: ровно пять ANDROID_KEYSTORE_*, каждый обязателен. Явный
# allowlist — производная от «не secrets: inherit»: новое имя секрета здесь
# означает, что контракт вызова расширили молча.
ALLOWED_SECRETS = {
    "ANDROID_KEYSTORE_BASE64",
    "ANDROID_KEYSTORE_PASSWORD",
    "ANDROID_KEY_ALIAS",
    "ANDROID_KEY_PASSWORD",
    "ANDROID_KEYSTORE_FINGERPRINT",
}
secrets = call.get("secrets")
want(isinstance(secrets, dict), "нет workflow_call.secrets")
want(
    set(secrets) == ALLOWED_SECRETS,
    "secrets обязаны быть ровно пять ANDROID_KEYSTORE_*, получено %r"
    % (sorted(secrets),),
)
for secret_name in sorted(secrets):
    spec = secrets[secret_name]
    want(
        isinstance(spec, dict) and spec.get("required") is True,
        "секрет %r обязан быть required: true" % (secret_name,),
    )

# 10.3 Выходы workflow_call указывают на outputs job'а build, а не на steps.
outputs = call.get("outputs")
want(isinstance(outputs, dict), "нет workflow_call.outputs")
want(
    set(outputs) == {"version", "commit", "signer-cn", "fingerprint", "artifact-name"},
    "outputs обязаны быть {version, commit, signer-cn, fingerprint, artifact-name}, "
    "получено %r" % (sorted(outputs),),
)
output_ref = re.compile(r"^\$\{\{ jobs\.build\.outputs\.[a-z-]+ \}\}$")
for output_name in sorted(outputs):
    spec = outputs[output_name]
    want(isinstance(spec, dict), "выход %r — не mapping" % (output_name,))
    want(
        output_ref.match(str(spec.get("value", ""))) is not None,
        "выход %r обязан ссылаться на jobs.build.outputs.<name>, получено %r"
        % (output_name, spec.get("value")),
    )

want(
    doc.get("permissions") == {"contents": "read"},
    "permissions уровня workflow должны быть {contents: read}, получено %r"
    % (doc.get("permissions"),),
)

jobs = doc.get("jobs")
want(isinstance(jobs, dict) and set(jobs) == {"build"}, "jobs обязан быть ровно {build}")
job = jobs["build"]
want(
    job.get("runs-on") == "ubuntu-24.04",
    "runs-on должен быть 'ubuntu-24.04', получено %r" % (job.get("runs-on"),),
)
want(
    job.get("timeout-minutes") == 120,
    "timeout-minutes должен быть 120, получено %r" % (job.get("timeout-minutes"),),
)
want(
    job.get("permissions") == {"contents": "read"},
    "permissions job'а build должны быть {contents: read}, получено %r"
    % (job.get("permissions"),),
)

steps = job.get("steps")
want(isinstance(steps, list) and steps, "у job'а build нет шагов")
names = [step.get("name") for step in steps]


def require_step(name):
    step = next((item for item in steps if item.get("name") == name), None)
    want(step is not None, "нет шага %r (есть: %r)" % (name, names))
    return step


by_name = {step.get("name"): step for step in steps}
pinned = re.compile(r"^[^@]+@[0-9a-f]{40}$")

# 10.4 Все uses: запинены полным 40-символьным SHA.
uses = [step["uses"] for step in steps if "uses" in step]
want(uses, "нет ни одного шага с 'uses:'")
for value in uses:
    want(
        pinned.match(value) is not None,
        "экшен не запинен на 40-символьный SHA: %r" % (value,),
    )

# 10.5 Каждый run: начинается с `set -euo pipefail`; `set -x` запрещён
#      (с ним в лог уезжают секреты из env).
run_steps = [
    (step.get("name") or step.get("id") or "#%d" % index, step["run"])
    for index, step in enumerate(steps)
    if "run" in step
]
want(run_steps, "нет ни одного шага с 'run:'")
for name, run in run_steps:
    lines = [line for line in str(run).splitlines() if line.strip()]
    want(
        bool(lines) and lines[0].strip() == "set -euo pipefail",
        "run-блок шага %r не начинается с 'set -euo pipefail'" % (name,),
    )
want(
    re.search(r"^[ \t]*set[ \t]+-[a-z]*x", text, re.M) is None,
    "build.yml не должен включать `set -x`",
)

# 10.6 Секреты: те же пять имён; TELEGRAM_* здесь не живут.
referenced_secrets = set(re.findall(r"secrets\.([A-Za-z0-9_]+)", text))
want(referenced_secrets, "workflow не ссылается ни на один секрет")
want(
    referenced_secrets <= ALLOWED_SECRETS,
    "недопустимые секреты: %r (разрешены только %r)"
    % (sorted(referenced_secrets - ALLOWED_SECRETS), sorted(ALLOWED_SECRETS)),
)
want(
    "TELEGRAM_" not in text,
    "TELEGRAM_* секреты живут только в beta.yml, не в build.yml",
)

# 10.7 Тулчейн: порядок фиксирован, Free disk space ровно один и раньше
#      setup-java/setup-python (иначе удалит JDK/Python из RUNNER_TOOL_CACHE).
TOOLCHAIN = [
    "Free disk space",
    "Setup Java 17",
    "Setup Python",
    "Install Android SDK",
    "Install Rust 1.97.1",
    "Install Zig 0.17.0",
    "Install cargo-ndk and cargo-zigbuild",
]
GATES = [
    "Gate: version lockup",
    "Gate: Kotlin unit tests",
    "Gate: Rust client",
    "Gate: Rust server (musl via zig wrappers)",
]
for name in TOOLCHAIN + GATES:
    require_step(name)
toolchain_positions = [names.index(name) for name in TOOLCHAIN]
want(
    toolchain_positions == sorted(toolchain_positions)
    and len(set(toolchain_positions)) == len(toolchain_positions),
    "порядок шагов тулчейна нарушен: %r"
    % (list(zip(TOOLCHAIN, toolchain_positions)),),
)
want(
    names.count("Free disk space") == 1,
    "шаг 'Free disk space' должен быть ровно один",
)
want(
    names.index("Free disk space") < names.index("Setup Java 17"),
    "'Free disk space' обязан идти до 'Setup Java 17' (иначе удалит JDK)",
)
want(
    names.index("Free disk space") < names.index("Setup Python"),
    "'Free disk space' обязан идти до 'Setup Python'",
)

# 10.8 Гейты — в фиксированном порядке и после всего тулчейна.
gate_positions = [names.index(name) for name in GATES]
want(
    gate_positions == sorted(gate_positions)
    and len(set(gate_positions)) == len(gate_positions),
    "порядок гейтов нарушен: %r" % (list(zip(GATES, gate_positions)),),
)
want(
    max(toolchain_positions) < min(gate_positions),
    "все гейты обязаны идти после шагов тулчейна",
)
want(
    by_name["Gate: Rust client"].get("working-directory") == "rust-client",
    "у 'Gate: Rust client' должен быть working-directory: rust-client",
)
want(
    by_name["Gate: Rust server (musl via zig wrappers)"].get("working-directory")
    == "rust-server",
    "у 'Gate: Rust server (musl via zig wrappers)' должен быть working-directory: rust-server",
)
want(
    "musl-zig-env.sh"
    in by_name["Gate: Rust server (musl via zig wrappers)"].get("run", ""),
    "серверный гейт обязан source'ить .github/scripts/musl-zig-env.sh",
)

# 10.9 Пины cargo-* совпадают с версиями в ключе кеша cargo-bin.
install_run = by_name["Install cargo-ndk and cargo-zigbuild"].get("run", "")
cache_key = str((by_name["Cache Cargo binaries"].get("with") or {}).get("key", ""))
for crate in ("cargo-ndk", "cargo-zigbuild"):
    match = re.search(
        r"cargo install %s --locked --version ([0-9][0-9A-Za-z.+-]*)" % re.escape(crate),
        install_run,
    )
    want(
        match is not None,
        "в шаге установки нет пина `cargo install %s --locked --version <X>`" % crate,
    )
    want(
        match.group(1) in cache_key,
        "ключ кеша 'Cache Cargo binaries' не содержит запиненной версии %s (%s)"
        % (crate, match.group(1)),
    )

# 10.10 Подпись, сборка и сверки — ровно в этом порядке и после гейтов.
SIGNING_AND_VERIFY = [
    "Restore keystore",
    "Build release APKs",
    "Verify native provenance",
    "Stage build outputs",
    "Verify APK signatures",
    "Verify APK identity",
    "Upload artifacts",
    "Cleanup keystore",
]
for name in SIGNING_AND_VERIFY:
    require_step(name)
signing_positions = [names.index(name) for name in SIGNING_AND_VERIFY]
want(
    signing_positions == sorted(signing_positions)
    and len(set(signing_positions)) == len(signing_positions),
    "порядок шагов подписи/сборки/сверки нарушен: %r"
    % (list(zip(SIGNING_AND_VERIFY, signing_positions)),),
)
want(
    max(gate_positions) < min(signing_positions),
    "шаги подписи/сборки/сверки обязаны идти после всех гейтов",
)

# 10.11 Каждый steps.<id>.outputs.* имеет шаг-производитель.
ids = [step["id"] for step in steps if "id" in step]
for required_id in ("version", "stage", "signcheck"):
    want(required_id in ids, "нет шага с id: %s" % required_id)
consumed = re.findall(r"steps\.([A-Za-z0-9_-]+)\.outputs\.", text)
want(consumed, "workflow не использует ни одного steps.<id>.outputs.*")
for producer in sorted(set(consumed)):
    want(
        producer in ids,
        "используется steps.%s.outputs.*, но шага с id: %s нет" % (producer, producer),
    )

# 10.12 Keystore удаляется всегда.
want(
    by_name["Cleanup keystore"].get("if") == "always()",
    "у 'Cleanup keystore' должен быть if: always(), получено %r"
    % (by_name["Cleanup keystore"].get("if"),),
)

# 10.13 Артефакт: имя в upload обязано дословно совпадать с выходом job'а,
#       иначе вызывающий не найдёт артефакт после успешной сборки.
job_outputs = job.get("outputs")
want(isinstance(job_outputs, dict), "у job'а build нет outputs")
want("artifact-name" in job_outputs, "у job'а build нет выхода artifact-name")
artifact_name = str(job_outputs["artifact-name"])
want(
    "jobs.build.outputs.artifact-name"
    in str(outputs["artifact-name"].get("value", "")),
    "on.workflow_call.outputs.artifact-name обязан ссылаться на "
    "jobs.build.outputs.artifact-name",
)
upload = by_name["Upload artifacts"]
want(
    pinned.match(str(upload.get("uses", ""))) is not None,
    "экшен 'Upload artifacts' не запинен на 40-символьный SHA: %r"
    % (upload.get("uses"),),
)
upload_with = upload.get("with") or {}
want(
    upload_with.get("name") == artifact_name,
    "у 'Upload artifacts' name должен дословно совпадать с "
    "jobs.build.outputs.artifact-name (%r), получено %r"
    % (artifact_name, upload_with.get("name")),
)
want(
    upload_with.get("path") == "${{ runner.temp }}/build-output",
    "у 'Upload artifacts' path должен быть ${{ runner.temp }}/build-output, получено %r"
    % (upload_with.get("path"),),
)
want(
    upload_with.get("retention-days") == 30,
    "у 'Upload artifacts' retention-days должен быть 30, получено %r"
    % (upload_with.get("retention-days"),),
)
want(
    upload_with.get("if-no-files-found") == "error",
    "у 'Upload artifacts' if-no-files-found должен быть error, получено %r"
    % (upload_with.get("if-no-files-found"),),
)

# 10.14 APK не передаются в --apk глобом.
for step in steps:
    run = str(step.get("run", ""))
    match = re.search(r"--apk[=\s]+\S*\*", run)
    want(
        match is None,
        "шаг %r передаёт APK в --apk глобом: %r — нужен цикл с отдельным --apk"
        % (step.get("name"), match.group(0) if match else ""),
    )

signature_run = by_name["Verify APK signatures"].get("run", "")
want(
    "--apk \"$f\"" in signature_run,
    "'Verify APK signatures' обязан собирать аргументы циклом с --apk \"$f\"",
)
want(
    "--apksigner" in signature_run,
    "'Verify APK signatures' обязан передавать --apksigner из запиненного build-tools",
)

# 10.15 Provenance: клиентский скрипт получает ABI-скоуп, серверный — нет.
#       Дефолт native_client_provenance.sh — все три ABI, поэтому сборка с
#       одним ABI упала бы уже после двадцатиминутной сборки.
provenance_run = by_name["Verify native provenance"].get("run", "")
provenance_code = [
    line
    for line in provenance_run.splitlines()
    if not line.lstrip().startswith("#")
]
want(
    "native_client_provenance.sh verify --abis=" in provenance_run,
    "'Verify native provenance' обязан передавать --abis клиентскому скрипту",
)
for line in provenance_code:
    if "native_client_provenance.sh" in line:
        want(
            "native_client_provenance.sh verify --abis=" in line,
            "вызов native_client_provenance.sh без --abis: %r" % (line.strip(),),
        )
server_lines = [line for line in provenance_code if "server_asset_provenance.sh" in line]
want(server_lines, "'Verify native provenance' обязан вызывать server_asset_provenance.sh")
for line in server_lines:
    want(
        "--abis" not in line,
        "server_asset_provenance.sh не знает --abis, получено %r" % (line.strip(),),
    )

# 10.16 Сборка получает ABI-скоуп и суффикс версии от вызывающего.
build_run = by_name["Build release APKs"].get("run", "")
for flag in ("-Pcsqtt.abis", "-Pcsqtt.versionSuffix"):
    want(flag in build_run, "'Build release APKs' обязан передавать %s" % flag)

# 10.17 Личность APK: пакет, версия, versionCode через aapt2.
identity_run = by_name["Verify APK identity"].get("run", "")
want(
    "aapt2" in identity_run,
    "'Verify APK identity' обязан читать badging через aapt2",
)
want(
    "csqtt.quic.amurcanov" in identity_run,
    "'Verify APK identity' обязан сверять package с csqtt.quic.amurcanov",
)
want(
    "versionName" in identity_run and "versionCode" in identity_run,
    "'Verify APK identity' обязан сверять versionName и versionCode",
)

# 10.18 Checkout идёт по sha вызывающего: ветки и теги внутрь не передаются.
checkout_with = by_name.get("Checkout", {}).get("with") or {}
want(
    checkout_with.get("ref") == "${{ inputs.ref }}",
    "у 'Checkout' должен быть ref: ${{ inputs.ref }}, получено %r"
    % (checkout_with.get("ref"),),
)

# 10.19 Сборка ассетов, note и публикация — работа вызывающего.
for forbidden in (
    "Collect release assets",
    "Generate release note",
    "Publish release",
    "Dry run: draft and discard",
):
    want(
        forbidden not in names,
        "build.yml не должен содержать шаг %r — это работа вызывающего"
        % (forbidden,),
    )

print("BUILD OK")
PY

# 11. beta.yml — бета-канал: push в main -> build.yml -> Telegram.
python3 - "$BETA" "$BUILD" "$WORKFLOW" <<'PY'
import re
import sys

import yaml

beta_path, build_path, release_path = sys.argv[1], sys.argv[2], sys.argv[3]

ALLOWED_SECRETS = {
    "ANDROID_KEYSTORE_BASE64",
    "ANDROID_KEYSTORE_PASSWORD",
    "ANDROID_KEY_ALIAS",
    "ANDROID_KEY_PASSWORD",
    "ANDROID_KEYSTORE_FINGERPRINT",
}
TELEGRAM_SECRETS = {"TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID"}


def die(message):
    sys.stderr.write("workflow-skeleton: beta.yml: %s\n" % message)
    raise SystemExit(1)


def want(condition, message):
    if not condition:
        die(message)


def load(path):
    with open(path, encoding="utf-8") as fh:
        source = fh.read()
    try:
        document = yaml.safe_load(source)
    except yaml.YAMLError as exc:
        die("%s: YAML не парсится: %s" % (path, exc))
    want(isinstance(document, dict), "%s: верхний уровень — не mapping" % path)
    return document, source


def trigger_block(document):
    # PyYAML читает `on` по правилам YAML 1.1 и превращает его в булев True.
    if "on" in document:
        return document["on"]
    return document.get(True)


def needs_list(job):
    needs = job.get("needs")
    if needs is None:
        return []
    if isinstance(needs, str):
        return [needs]
    want(isinstance(needs, list), "needs должен быть строкой или списком")
    return needs


doc, text = load(beta_path)

want(
    doc.get("name") == "Beta",
    "name должен быть 'Beta', получено %r" % (doc.get("name"),),
)

triggers = trigger_block(doc)
want(isinstance(triggers, dict), "блок триггеров 'on' — не mapping")
push = triggers.get("push")
want(isinstance(push, dict), "нет триггера push")
want(
    push.get("branches") == ["main"],
    "push.branches должен быть ['main'], получено %r" % (push.get("branches"),),
)
want(
    "workflow_dispatch" in triggers,
    "нет триггера workflow_dispatch: ручной запуск — предохранитель беты",
)

want(
    doc.get("permissions") == {"contents": "read"},
    "permissions уровня workflow должны быть {contents: read}, получено %r"
    % (doc.get("permissions"),),
)

# У GitHub по умолчанию `queue: single`: новый прогон отменяет ОЖИДАЮЩИЙ, и
# `cancel-in-progress: false` спасает только уже идущий. При трёх пушах второй
# коммит не собрался бы вовсе и сообщения не было бы. Поэтому блока нет вовсе,
# а не «есть, но с cancel-in-progress: false».
want(
    "concurrency" not in doc,
    "в beta.yml не должно быть блока concurrency: queue: single по умолчанию "
    "отменял бы ожидающий прогон",
)
want("contents: write" not in text, "beta.yml не публикует релизы: contents: write запрещён")
want("inherit" not in text, "секреты передаются явным списком, не inherit")

jobs = doc.get("jobs")
want(isinstance(jobs, dict), "нет блока jobs")
want(
    set(jobs) == {"version", "build", "notify"},
    "jobs обязаны быть ровно {version, build, notify}, получено %r"
    % (sorted(jobs),),
)

step_output_ref = re.compile(r"^\$\{\{ steps\.([a-z0-9_-]+)\.outputs\.([a-z0-9_-]+) \}\}$")


def step_ids(job):
    return [step.get("id") for step in (job.get("steps") or []) if "id" in step]


def by_name(job):
    return {step.get("name"): step for step in (job.get("steps") or [])}


def require_step(mapping, name, job_label):
    step = mapping.get(name)
    want(step is not None, "в job %s нет шага %r" % (job_label, name))
    return step


# --- version -----------------------------------------------------------------
version_job = jobs["version"]
want(isinstance(version_job, dict), "job version — не mapping")
want(
    version_job.get("runs-on") == "ubuntu-24.04",
    "version.runs-on должен быть 'ubuntu-24.04', получено %r"
    % (version_job.get("runs-on"),),
)
want(
    version_job.get("permissions") == {"contents": "read"},
    "permissions job'а version должны быть {contents: read}, получено %r"
    % (version_job.get("permissions"),),
)
want(
    isinstance(version_job.get("timeout-minutes"), int),
    "version.timeout-minutes должен быть целым числом, получено %r"
    % (version_job.get("timeout-minutes"),),
)

VERSION_OUTPUTS = {"commit", "version", "version-code"}
version_outputs = version_job.get("outputs")
want(isinstance(version_outputs, dict), "у job'а version нет outputs")
want(
    set(version_outputs) == VERSION_OUTPUTS,
    "outputs version обязаны быть %r, получено %r"
    % (sorted(VERSION_OUTPUTS), sorted(version_outputs)),
)
version_ids = step_ids(version_job)
for output_name in sorted(VERSION_OUTPUTS):
    match = step_output_ref.match(str(version_outputs[output_name]))
    want(
        match is not None,
        "version.outputs.%s обязан ссылаться на steps.<id>.outputs.<name>, получено %r"
        % (output_name, version_outputs.get(output_name)),
    )
    want(
        match.group(1) in version_ids,
        "version.outputs.%s читает steps.%s.outputs.*, но шага с id: %s нет"
        % (output_name, match.group(1), match.group(1)),
    )

version_by_name = by_name(version_job)
version_names = [step.get("name") for step in (version_job.get("steps") or [])]

checkout = require_step(version_by_name, "Checkout", "version")
checkout_with = checkout.get("with") or {}
want(
    checkout_with.get("fetch-depth") == 1,
    "Checkout в version обязан брать fetch-depth: 1, получено %r"
    % (checkout_with.get("fetch-depth"),),
)
want(
    checkout_with.get("persist-credentials") is False,
    "Checkout в version обязан ставить persist-credentials: false",
)

bot = require_step(version_by_name, "Check bot configuration", "version")
bot_env = bot.get("env") or {}
want(
    bot_env.get("TELEGRAM_BOT_TOKEN") == "${{ secrets.TELEGRAM_BOT_TOKEN }}",
    "Check bot configuration обязан брать TELEGRAM_BOT_TOKEN из секрета, получено %r"
    % (bot_env.get("TELEGRAM_BOT_TOKEN"),),
)
want(
    bot_env.get("TELEGRAM_CHAT_ID") == "${{ secrets.TELEGRAM_CHAT_ID }}",
    "Check bot configuration обязан брать TELEGRAM_CHAT_ID из секрета, получено %r"
    % (bot_env.get("TELEGRAM_CHAT_ID"),),
)
bot_run = str(bot.get("run", ""))
for fragment in ("TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID", "exit 1"):
    want(
        fragment in bot_run,
        "Check bot configuration обязан падать на пустом %s, получено:\n%s"
        % (fragment, bot_run),
    )

resolve = require_step(version_by_name, "Resolve beta version", "version")
want(resolve.get("id") == "version", "у 'Resolve beta version' должен быть id: version")
resolve_run = str(resolve.get("run", ""))
for fragment in ("beta-version.sh", "--root", "--branch"):
    want(
        fragment in resolve_run,
        "'Resolve beta version' обязан содержать %r, получено:\n%s"
        % (fragment, resolve_run),
    )
resolve_env = resolve.get("env") or {}
want(
    "github.ref_name" in str(resolve_env.get("REF_NAME", "")),
    "env.REF_NAME обязан ссылаться на github.ref_name, получено %r"
    % (resolve_env.get("REF_NAME"),),
)
want(
    version_names.index("Check bot configuration") < version_names.index("Resolve beta version"),
    "Check bot configuration обязан идти до Resolve beta version (и до сборки): "
    "пустой секрет должен ронять прогон за секунды",
)

# --- build (reusable workflow) -----------------------------------------------
build_job = jobs["build"]
want(isinstance(build_job, dict), "job build — не mapping")
want(
    needs_list(build_job) == ["version"],
    "build.needs обязан быть ['version'], получено %r" % (build_job.get("needs"),),
)
want(
    build_job.get("uses") == "./.github/workflows/build.yml",
    "build.uses обязан быть './.github/workflows/build.yml', получено %r"
    % (build_job.get("uses"),),
)
for forbidden_key in ("runs-on", "timeout-minutes"):
    want(
        forbidden_key not in build_job,
        "у job'а build не должно быть %r: он вызывает reusable workflow"
        % forbidden_key,
    )
want(
    build_job.get("permissions") == {"contents": "read"},
    "permissions job'а build должны быть {contents: read}, получено %r"
    % (build_job.get("permissions"),),
)
build_with = build_job.get("with")
want(isinstance(build_with, dict), "у build нет with")
want(
    "needs.version.outputs.commit" in str(build_with.get("ref", "")),
    "build.with.ref обязан брать needs.version.outputs.commit, получено %r"
    % (build_with.get("ref"),),
)
want(
    "needs.version.outputs.version" in str(build_with.get("version-name", "")),
    "build.with.version-name обязан брать needs.version.outputs.version, получено %r"
    % (build_with.get("version-name"),),
)
want(
    "needs.version.outputs.version-code"
    in str(build_with.get("expected-version-code", "")),
    "build.with.expected-version-code обязан брать needs.version.outputs.version-code, "
    "получено %r" % (build_with.get("expected-version-code"),),
)
want(
    build_with.get("abis") == "arm64-v8a",
    "build.with.abis обязан быть 'arm64-v8a', получено %r"
    % (build_with.get("abis"),),
)

build_secrets = build_job.get("secrets") or {}
want(isinstance(build_secrets, dict), "у build нет secrets")
want(
    set(build_secrets) == ALLOWED_SECRETS,
    "build.secrets обязан перечислять ровно пять ANDROID_KEYSTORE_*, получено %r"
    % (sorted(build_secrets),),
)
for secret_name in sorted(build_secrets):
    want(
        build_secrets[secret_name] == "${{ secrets.%s }}" % secret_name,
        "build.secrets.%s обязан быть ${{ secrets.%s }}, получено %r"
        % (secret_name, secret_name, build_secrets[secret_name]),
    )

# --- notify ------------------------------------------------------------------
notify_job = jobs["notify"]
want(isinstance(notify_job, dict), "job notify — не mapping")
notify_needs = needs_list(notify_job)
for required in ("version", "build"):
    want(
        required in notify_needs,
        "notify.needs обязан содержать %r, получено %r" % (required, notify_needs),
    )
want(
    notify_job.get("runs-on") == "ubuntu-24.04",
    "notify.runs-on должен быть 'ubuntu-24.04', получено %r"
    % (notify_job.get("runs-on"),),
)
want(
    isinstance(notify_job.get("timeout-minutes"), int),
    "notify.timeout-minutes должен быть целым числом, получено %r"
    % (notify_job.get("timeout-minutes"),),
)
want(
    notify_job.get("permissions") == {"contents": "read"},
    "permissions job'а notify должны быть {contents: read}, получено %r"
    % (notify_job.get("permissions"),),
)

notify_by_name = by_name(notify_job)
pinned = re.compile(r"^[^@]+@[0-9a-f]{40}$")

download = require_step(notify_by_name, "Download build artifact", "notify")
want(
    pinned.match(str(download.get("uses", ""))) is not None,
    "'Download build artifact' не запинен на 40-символьный SHA: %r"
    % (download.get("uses"),),
)
download_with = download.get("with") or {}
want(
    download_with.get("name") == "${{ needs.build.outputs.artifact-name }}",
    "'Download build artifact'.name обязан быть needs.build.outputs.artifact-name, "
    "получено %r" % (download_with.get("name"),),
)

verify = require_step(notify_by_name, "Verify built commit", "notify")
verify_env = verify.get("env") or {}
want(
    verify_env.get("BUILT") == "${{ needs.build.outputs.commit }}",
    "env.BUILT обязан быть needs.build.outputs.commit, получено %r"
    % (verify_env.get("BUILT"),),
)
want(
    verify_env.get("EXPECTED") == "${{ needs.version.outputs.commit }}",
    "env.EXPECTED обязан быть needs.version.outputs.commit, получено %r"
    % (verify_env.get("EXPECTED"),),
)
verify_run = str(verify.get("run", ""))
want(
    "needs.build.outputs.commit" in text
    and "needs.version.outputs.commit" in text
    and '"$BUILT" == "$EXPECTED"' in verify_run,
    "'Verify built commit' обязан сверять needs.build.outputs.commit с "
    "needs.version.outputs.commit до отправки",
)

prepare = require_step(notify_by_name, "Prepare Telegram document", "notify")
want(prepare.get("id") == "document", "у 'Prepare Telegram document' должен быть id: document")
prepare_env = prepare.get("env") or {}
want(
    "needs.build.outputs.version" in str(prepare_env.get("VERSION", "")),
    "env.VERSION обязан брать needs.build.outputs.version, получено %r"
    % (prepare_env.get("VERSION"),),
)
want(
    "needs.build.outputs.commit" in str(prepare_env.get("COMMIT", "")),
    "env.COMMIT обязан брать needs.build.outputs.commit, получено %r"
    % (prepare_env.get("COMMIT"),),
)
prepare_run = str(prepare.get("run", ""))
for fragment in ("*arm64-v8a*.apk", "caption.txt", 'echo "path=$dst" >> "$GITHUB_OUTPUT"'):
    want(
        fragment in prepare_run,
        "'Prepare Telegram document' обязан содержать %r, получено:\n%s"
        % (fragment, prepare_run),
    )
want(
    "VERSION" in prepare_run and "COMMIT" in prepare_run,
    "'Prepare Telegram document' обязан подставлять версию и коммит в caption",
)

send = require_step(notify_by_name, "Send to Telegram", "notify")
send_run = str(send.get("run", ""))
want(
    "bash .github/scripts/telegram-send.sh" in send_run,
    "'Send to Telegram' обязан вызывать .github/scripts/telegram-send.sh",
)
want(
    send_run.count("--document") == 1,
    "'Send to Telegram' обязан передавать ровно один --document, получено %d"
    % (send_run.count("--document"),),
)
want(
    "--caption-file" in send_run,
    "'Send to Telegram' обязан передавать --caption-file",
)
want(
    "for " not in send_run and "*" not in send_run.split("--document", 1)[-1],
    "'Send to Telegram' отправляет один файл: циклы и глобы в аргументе недопустимы",
)
send_env = send.get("env") or {}
want(
    send_env.get("TELEGRAM_BOT_TOKEN") == "${{ secrets.TELEGRAM_BOT_TOKEN }}",
    "Send to Telegram обязан брать TELEGRAM_BOT_TOKEN из секрета, получено %r"
    % (send_env.get("TELEGRAM_BOT_TOKEN"),),
)
want(
    send_env.get("TELEGRAM_CHAT_ID") == "${{ secrets.TELEGRAM_CHAT_ID }}",
    "Send to Telegram обязан брать TELEGRAM_CHAT_ID из секрета, получено %r"
    % (send_env.get("TELEGRAM_CHAT_ID"),),
)

# --- общие инварианты beta.yml ----------------------------------------------
referenced_secrets = set(re.findall(r"secrets\.([A-Za-z0-9_]+)", text))
want(referenced_secrets, "beta.yml не ссылается ни на один секрет")
unexpected = referenced_secrets - (ALLOWED_SECRETS | TELEGRAM_SECRETS)
want(
    not unexpected,
    "beta.yml: недопустимые секреты: %r" % (sorted(unexpected),),
)
want(
    TELEGRAM_SECRETS <= referenced_secrets,
    "beta.yml обязан использовать оба секрета: %r" % (sorted(TELEGRAM_SECRETS),),
)

for job_id, job in jobs.items():
    permissions = job.get("permissions")
    want(
        permissions == {"contents": "read"},
        "permissions job'а %s обязаны быть {contents: read}, получено %r"
        % (job_id, permissions),
    )
    for step in job.get("steps") or []:
        if "uses" in step:
            value = str(step["uses"])
            want(
                value == "./.github/workflows/build.yml"
                or pinned.match(value) is not None,
                "beta.yml: экшен не запинен на 40-символьный SHA: %r" % (value,),
            )

# --- контракт вызова build.yml ----------------------------------------------
build_doc, build_text = load(build_path)
release_doc, release_text = load(release_path)
build_call = trigger_block(build_doc)["workflow_call"]
declared_inputs = set((build_call.get("inputs") or {}).keys())
declared_secrets = set((build_call.get("secrets") or {}).keys())
declared_outputs = set((build_call.get("outputs") or {}).keys())

want(
    set(build_with) <= declared_inputs,
    "beta.yml передаёт необъявленный вход build.yml: %r"
    % (sorted(set(build_with) - declared_inputs),),
)
want(
    set(build_secrets) <= declared_secrets,
    "beta.yml передаёт необъявленный секрет build.yml: %r"
    % (sorted(set(build_secrets) - declared_secrets),),
)
consumed_build_outputs = set(
    re.findall(r"needs\.build\.outputs\.([a-z0-9_-]+)", text)
)
want(
    consumed_build_outputs <= declared_outputs,
    "beta.yml читает необъявленный выход build.yml: %r"
    % (sorted(consumed_build_outputs - declared_outputs),),
)

# --- четыре проверки безусловно по всем трём файлам -------------------------
documents = (
    ("build.yml", build_doc, build_text),
    ("release.yml", release_doc, release_text),
    ("beta.yml", doc, text),
)

# 1. Каждый needs.<job>.outputs.<name> объявлен, и у каждого объявленного
#    выхода есть job-производитель. Опечатка иначе даёт пустую строку.
step_output_refs = re.compile(r"steps\.([A-Za-z0-9_-]+)\.outputs\.")
for label, document, source in documents:
    jobs_doc = document.get("jobs") or {}
    declared = {}
    for job_id, job in jobs_doc.items():
        outputs = job.get("outputs") or {}
        if outputs:
            want(isinstance(outputs, dict), "%s: outputs job'а %s — не mapping" % (label, job_id))
        ids = {step.get("id") for step in (job.get("steps") or []) if "id" in step}
        for output_name, value in (outputs or {}).items():
            producers = step_output_refs.findall(str(value))
            want(
                producers,
                "%s: job %s: outputs.%s не ссылается на steps.<id>.outputs.* (%r)"
                % (label, job_id, output_name, value),
            )
            for producer in producers:
                want(
                    producer in ids,
                    "%s: job %s: outputs.%s читает steps.%s.outputs.*, но шага с id: %s нет"
                    % (label, job_id, output_name, producer, producer),
                )
        declared[job_id] = set((outputs or {}).keys())

    for job_id in jobs_doc:
        for source_job, output_name in re.findall(
            r"needs\.([a-z0-9_-]+)\.outputs\.([a-z0-9_-]+)", source
        ):
            want(
                source_job in jobs_doc,
                "%s: job %s читает needs.%s.outputs.*, но такого job'а нет"
                % (label, job_id, source_job),
            )
            # У job'а с reusable workflow выходы объявлены в
            # on.workflow_call.outputs build.yml — их сверяет контракт выше.
            if "uses" in jobs_doc[source_job]:
                continue
            want(
                output_name in declared[source_job],
                "%s: job %s читает needs.%s.outputs.%s, но выход не объявлен в jobs.%s.outputs"
                % (label, job_id, source_job, output_name, source_job),
            )

# 2. Allowlist секретов по каждому файлу отдельно; TELEGRAM_* — только в бете.
for label, document, source in documents:
    allowed = ALLOWED_SECRETS | (TELEGRAM_SECRETS if label == "beta.yml" else set())
    used = set(re.findall(r"secrets\.([A-Za-z0-9_]+)", source))
    want(used, "%s: workflow не ссылается ни на один секрет" % label)
    want(
        used <= allowed,
        "%s: недопустимые секреты: %r (разрешены %r)"
        % (label, sorted(used - allowed), sorted(allowed)),
    )
    if label != "beta.yml":
        want(
            "TELEGRAM_" not in source,
            "%s: TELEGRAM_* секреты живут только в beta.yml" % label,
        )

# 3. --apk без глоба и set -euo pipefail в каждом run: во всех трёх файлах.
for label, document, source in documents:
    for job_id, job in (document.get("jobs") or {}).items():
        for step in job.get("steps") or []:
            if "run" not in step:
                continue
            run = str(step["run"])
            lines = [line for line in run.splitlines() if line.strip()]
            want(
                bool(lines) and lines[0].strip() == "set -euo pipefail",
                "%s: run-блок шага %r не начинается с 'set -euo pipefail'"
                % (label, step.get("name") or step.get("id") or "?"),
            )
            match = re.search(r"--apk[=\s]+\S*\*", run)
            want(
                match is None,
                "%s: шаг %r передаёт APK в --apk глобом: %r"
                % (label, step.get("name"), match.group(0) if match else ""),
            )

# 4. Имя артефакта: upload.name == jobs.build.outputs.artifact-name, а
#    on.workflow_call.outputs.artifact-name ссылается на тот же выход.
build_job_outputs = build_doc.get("jobs", {}).get("build", {}).get("outputs") or {}
artifact_job_output = str(build_job_outputs.get("artifact-name", ""))
artifact_call_value = str(
    ((build_call.get("outputs") or {}).get("artifact-name") or {}).get("value", "")
)
upload = next(
    (
        step
        for step in build_doc.get("jobs", {}).get("build", {}).get("steps", [])
        if step.get("name") == "Upload artifacts"
    ),
    None,
)
want(upload is not None, "build.yml: нет шага 'Upload artifacts'")
upload_name = str((upload.get("with") or {}).get("name", ""))
want(
    upload_name == artifact_job_output,
    "build.yml: 'Upload artifacts'.name (%r) обязан совпадать с "
    "jobs.build.outputs.artifact-name (%r)" % (upload_name, artifact_job_output),
)
want(
    "jobs.build.outputs.artifact-name" in artifact_call_value,
    "build.yml: on.workflow_call.outputs.artifact-name обязан ссылаться на "
    "jobs.build.outputs.artifact-name, получено %r" % (artifact_call_value,),
)

print("BETA OK")
PY

# 7. Вызванные helper-скрипты обязаны существовать и быть исполняемыми:
#    все шесть уже в репозитории, «ещё не написан» больше не аргумент.
#    Проверка охватывает все три workflow, включая beta.yml.
workflows=("$WORKFLOW" "$BUILD" "$BETA")

for workflow in "${workflows[@]}"; do
    refs=$(grep -oE 'bash \.github/scripts/[A-Za-z0-9._-]+\.sh' "$workflow" || true)
    if [[ -z "$refs" ]]; then
        printf 'workflow-skeleton: %s не вызывает ни одного .github/scripts/*.sh\n' "$workflow" >&2
        exit 1
    fi

    while IFS= read -r ref; do
        [[ -n "$ref" ]] || continue
        name=${ref#bash .github/scripts/}
        path="$REPO_ROOT/.github/scripts/$name"
        if [[ ! -e "$path" ]]; then
            printf 'workflow-skeleton: %s вызывает %s, но файла %s нет\n' \
                "$(basename -- "$workflow")" "$name" "$path" >&2
            exit 1
        elif [[ ! -f "$path" ]]; then
            printf 'workflow-skeleton: %s существует, но это не файл\n' "$path" >&2
            exit 1
        elif [[ ! -x "$path" ]]; then
            printf 'workflow-skeleton: %s существует, но не исполняем (нужен chmod +x)\n' "$path" >&2
            exit 1
        else
            printf 'OK %s\n' "$name"
        fi
    done <<<"$refs"
done

printf 'структура workflow и вызовы скриптов в порядке\n'
