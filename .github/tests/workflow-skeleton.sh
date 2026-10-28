#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
#
# Статические проверки скелета релизного workflow (.github/workflows/release.yml).
#
# Проверяется только то, что можно проверить без запуска раннера:
#   * YAML парсится и структура триггеров/job'а верна;
#   * permissions разнесены между workflow и job;
#   * concurrency — константная группа;
#   * все `uses:` запинены полным 40-символьным SHA;
#   * порядок шагов с `id:` и связка `steps.<id>.outputs.*` -> производитель;
#   * `secrets.*` — только пять заведённых имён keystore/подписи;
#   * каждый `run:` начинается с `set -euo pipefail`;
#   * вызванные `bash .github/scripts/<name>.sh` существуют и исполняемы;
#   * тулчейн (Free disk space -> SDK -> Rust -> Zig -> cargo-*) и гейты
#     (локап -> Kotlin -> Rust client -> Rust server musl) присутствуют
#     и идут в фиксированном порядке после `Resolve release target`;
#   * версии cargo-ndk/cargo-zigbuild запинены в шаге установки и входят
#     в ключ кеша `Cache Cargo binaries`;
#   * шаги подписи/сборки/сверки/публикации присутствуют и идут после гейтов;
#   * `Cleanup keystore` выполняется всегда, `Dry run`/`Publish release`
#     разведены строгими сравнениями `== 'true'` / `== 'false'`;
#   * APK не передаются в сверку глобом (`--apk` со звёздочкой).
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

if [[ ! -f "$WORKFLOW" ]]; then
    printf 'workflow-skeleton: нет файла %s\n' "$WORKFLOW" >&2
    exit 1
fi

python3 - "$WORKFLOW" <<'PY'
import re
import sys

import yaml

workflow_path = sys.argv[1]
with open(workflow_path, encoding="utf-8") as fh:
    text = fh.read()


def die(message):
    sys.stderr.write("workflow-skeleton: %s\n" % message)
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
    doc.get("name") == "Release",
    "name должен быть 'Release', получено %r" % (doc.get("name"),),
)

# PyYAML читает `on` по правилам YAML 1.1 и превращает его в булев True —
# это ожидаемо, файл под это подгонять не нужно.
if "on" in doc:
    triggers = doc["on"]
elif True in doc:
    triggers = doc[True]
else:
    die("нет блока триггеров 'on'")
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
want("release" in jobs, "нет job'а 'release'")
job = jobs["release"]
want(isinstance(job, dict), "job 'release' — не mapping")

want(
    job.get("runs-on") == "ubuntu-24.04",
    "runs-on должен быть 'ubuntu-24.04', получено %r" % (job.get("runs-on"),),
)
want(
    job.get("timeout-minutes") == 120,
    "timeout-minutes должен быть 120, получено %r" % (job.get("timeout-minutes"),),
)
want(
    job.get("permissions") == {"contents": "write"},
    "permissions job'а release должны быть {contents: write}, получено %r"
    % (job.get("permissions"),),
)

steps = job.get("steps")
want(isinstance(steps, list) and steps, "у job'а release нет шагов")

# 3. Все uses: запинены полным 40-символьным SHA.
pinned = re.compile(r"^[^@]+@[0-9a-f]{40}$")
uses = [step["uses"] for step in steps if "uses" in step]
want(uses, "нет ни одного шага с 'uses:'")
for value in uses:
    want(
        pinned.match(value) is not None,
        "экшен не запинен на 40-символьный SHA: %r" % (value,),
    )

# 4. Шаги с id: начало фиксировано — ['start', 'resolve', 'target'].
ids = [step["id"] for step in steps if "id" in step]
want(
    ids[:3] == ["start", "resolve", "target"],
    "первые шаги с id: должны быть ['start', 'resolve', 'target'], получено %r"
    % (ids,),
)

# 5. У каждого steps.<id>.outputs.* есть шаг-производитель; шаг target
#    использует выход resolve.commit (иначе dispatch собрал бы дерево main).
consumed = re.findall(r"steps\.([A-Za-z0-9_-]+)\.outputs\.", text)
want(consumed, "workflow не использует ни одного steps.<id>.outputs.*")
for producer in sorted(set(consumed)):
    want(
        producer in ids,
        "используется steps.%s.outputs.*, но шага с id: %s нет" % (producer, producer),
    )

target = next((step for step in steps if step.get("id") == "target"), None)
want(target is not None, "нет шага с id: target")
want(
    "${{ steps.resolve.outputs.commit }}" in target.get("run", ""),
    "шаг target обязан делать checkout по ${{ steps.resolve.outputs.commit }}",
)

# 6. Секреты: допустимы ровно пять имён keystore/подписи. Любое другое имя
#    означает, что workflow тянет секрет, которого в репозитории не завели.
ALLOWED_SECRETS = {
    "ANDROID_KEYSTORE_BASE64",
    "ANDROID_KEYSTORE_PASSWORD",
    "ANDROID_KEY_ALIAS",
    "ANDROID_KEY_PASSWORD",
    "ANDROID_KEYSTORE_FINGERPRINT",
}
referenced_secrets = set(re.findall(r"secrets\.([A-Za-z0-9_]+)", text))
want(referenced_secrets, "workflow не ссылается ни на один секрет")
unexpected_secrets = referenced_secrets - ALLOWED_SECRETS
want(
    not unexpected_secrets,
    "недопустимые секреты: %r (разрешены только %r)"
    % (sorted(unexpected_secrets), sorted(ALLOWED_SECRETS)),
)

# Производители выходов signcheck/collect обязаны быть объявлены шагами с id:.
for required_id in ("collect", "signcheck"):
    want(required_id in ids, "нет шага с id: %s" % required_id)

# 8. Каждый run: начинается с `set -euo pipefail`.
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

print("STRUCT OK")
PY

# 9. Тулчейн и гейты: все шаги на месте, порядок фиксирован.
python3 - "$WORKFLOW" <<'PY'
import re
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as fh:
    text = fh.read()
doc = yaml.safe_load(text)


def die(message):
    sys.stderr.write("workflow-skeleton: %s\n" % message)
    raise SystemExit(1)


def want(condition, message):
    if not condition:
        die(message)


steps = doc["jobs"]["release"]["steps"]
names = [step.get("name") for step in steps]
pinned = re.compile(r"^[^@]+@[0-9a-f]{40}$")

TOOLCHAIN = [
    "Free disk space",
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
    want(name in names, "нет шага %r (есть: %r)" % (name, names))

# Порядок: индексы строго возрастают внутри каждой группы.
for group, label in ((TOOLCHAIN, "тулчейна"), (GATES, "гейтов")):
    positions = [names.index(name) for name in group]
    want(
        positions == sorted(positions) and len(set(positions)) == len(positions),
        "порядок шагов %s нарушен: %r" % (label, list(zip(group, positions))),
    )

resolved_at = names.index("Resolve release target")
want(
    resolved_at < min(names.index(name) for name in GATES),
    "шаг 'Resolve release target' обязан идти раньше всех гейтов",
)
want(
    names.index("Free disk space") < names.index("Install Android SDK"),
    "'Free disk space' обязан идти до 'Install Android SDK'",
)
# ...и до setup-java/setup-python: шаг удаляет /opt/hostedtoolcache, то есть
# RUNNER_TOOL_CACHE, куда эти экшены ставят JDK и Python. Удаление после них
# оставляет висячий JAVA_HOME, и sdkmanager/Gradle падают на следующем шаге.
want(
    names.index("Free disk space") < names.index("Setup Java 17"),
    "'Free disk space' обязан идти до 'Setup Java 17' (иначе удалит JDK)",
)
want(
    names.index("Free disk space") < names.index("Setup Python"),
    "'Free disk space' обязан идти до 'Setup Python'",
)

# workflow_dispatch-входы не превращаются в INPUT_* сами: шаг resolve обязан
# пробросить их явно, иначе ручной запуск падает на пустом INPUT_TAG_NAME.
resolve_step = next(
    step for step in steps if step.get("name") == "Resolve release target"
)
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
# Ровно один Free disk space: второй экземпляр прошёл бы проверки порядка.
want(
    names.count("Free disk space") == 1,
    "шаг 'Free disk space' должен быть ровно один",
)

# Гейты идут после тулчейна: Ubuntu-раннер без своего SDK/zig их не пройдёт.
want(
    max(names.index(name) for name in TOOLCHAIN)
    < min(names.index(name) for name in GATES),
    "все гейты обязаны идти после шагов тулчейна",
)

# Rust-гейты проверяют именно те крейты.
by_name = {step.get("name"): step for step in steps}
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

# Версии cargo-* запинены И в шаге установки, И в ключе кеша cargo-bin:
# иначе смена пина не инвалидирует кеш и в ~/.cargo/bin останется старый бинарь.
install_run = by_name["Install cargo-ndk and cargo-zigbuild"].get("run", "")
for crate in ("cargo-ndk", "cargo-zigbuild"):
    match = re.search(
        r"cargo install %s --locked --version ([0-9][0-9A-Za-z.+-]*)" % re.escape(crate),
        install_run,
    )
    want(match is not None, "в шаге установки нет пина `cargo install %s --locked --version <X>`" % crate)
    version = match.group(1)

    cache_key = None
    for step in steps:
        if step.get("name") == "Cache Cargo binaries":
            cache_key = str((step.get("with") or {}).get("key", ""))
    want(cache_key is not None, "нет шага 'Cache Cargo binaries'")
    want(
        version in cache_key,
        "ключ кеша 'Cache Cargo binaries' не содержит запиненной версии %s (%s)"
        % (crate, version),
    )

# Шаги подписи, сборки, сверки и публикации: имена фиксированы, порядок
# обязателен. Все они идут после гейтов: keystore и сборка — самая дорогая
# часть прогона, её нельзя начинать до зелёных гейтов.
SIGNING_AND_PUBLISH = [
    "Restore keystore",
    "Build release APKs",
    "Verify native provenance",
    "Collect release assets",
    "Verify APK signatures",
    "Verify APK identity",
    "Upload artifacts",
    "Cleanup keystore",
    "Generate release note",
    "Dry run: draft and discard",
    "Publish release",
]

for name in SIGNING_AND_PUBLISH:
    want(name in names, "нет шага %r (есть: %r)" % (name, names))

signing_positions = [names.index(name) for name in SIGNING_AND_PUBLISH]
want(
    signing_positions == sorted(signing_positions)
    and len(set(signing_positions)) == len(signing_positions),
    "порядок шагов подписи/публикации нарушен: %r"
    % (list(zip(SIGNING_AND_PUBLISH, signing_positions)),),
)
want(
    max(names.index(name) for name in GATES) < min(signing_positions),
    "шаги подписи/публикации обязаны идти после всех гейтов",
)

# Keystore удаляется всегда — в том числе когда сверка или загрузка упали.
cleanup = by_name["Cleanup keystore"]
want(
    cleanup.get("if") == "always()",
    "у 'Cleanup keystore' должен быть if: always(), получено %r"
    % (cleanup.get("if"),),
)

# dry_run разводится строгими сравнениями: при опечатке в id: выход пустой,
# и `!= 'true'` опубликовал бы в dry-run, а `== 'false'` — нет.
dry_run_if = str(by_name["Dry run: draft and discard"].get("if", ""))
publish_if = str(by_name["Publish release"].get("if", ""))
want(
    re.search(r"steps\.resolve\.outputs\.dry_run\s*==\s*'true'", dry_run_if),
    "у 'Dry run: draft and discard' должен быть if с == 'true', получено %r"
    % (dry_run_if,),
)
want(
    re.search(r"steps\.resolve\.outputs\.dry_run\s*==\s*'false'", publish_if),
    "у 'Publish release' должен быть if с == 'false', получено %r" % (publish_if,),
)
want(
    "!=" not in publish_if,
    "условие 'Publish release' не должно строиться на !=: получено %r" % (publish_if,),
)
want(
    "--dry-run" in by_name["Dry run: draft and discard"].get("run", ""),
    "'Dry run: draft and discard' обязан вызывать publish-release.sh с --dry-run",
)

# Upload artifacts: экшен запинен полным SHA (общая проверка выше) плюс
# обязательные параметры артефакта.
upload_uses = str(by_name["Upload artifacts"].get("uses", ""))
want(
    pinned.match(upload_uses) is not None,
    "экшен 'Upload artifacts' не запинен на 40-символьный SHA: %r" % (upload_uses,),
)
upload_with = by_name["Upload artifacts"].get("with") or {}
want(
    upload_with.get("name") == "release-assets-${{ steps.resolve.outputs.tag }}",
    "у 'Upload artifacts' name должен быть release-assets-<tag>, получено %r"
    % (upload_with.get("name"),),
)
want(
    upload_with.get("path") == "${{ runner.temp }}/release-assets",
    "у 'Upload artifacts' path должен быть ${{ runner.temp }}/release-assets, получено %r"
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

# APK передаются в сверку по одному: `--apk` со звёздочкой развернулся бы в
# позиционные аргументы, а verify-signing-identity.sh их отвергает — то есть
# падение случилось бы уже после сборки и подписи.
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

# --asset тоже повторяемый: `--asset "${ASSETS[@]}"` отдаёт первый файл как
# значение флага, а остальные — позиционными аргументами, и publish-release.sh
# их отвергает. Ровно на этом упал первый настоящий прогон.
# Комментарии из run-блока выкидываем: в них эту строку можно цитировать.
for step_name in ("Dry run: draft and discard", "Publish release"):
    code = "\n".join(
        line
        for line in str(by_name[step_name].get("run", "")).splitlines()
        if not line.lstrip().startswith("#")
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

print("STEPS OK")
PY

# 7. Вызванные helper-скрипты обязаны существовать и быть исполняемыми:
#    все шесть уже в репозитории, «ещё не написан» больше не аргумент.
refs=$(grep -oE 'bash \.github/scripts/[A-Za-z0-9._-]+\.sh' "$WORKFLOW" || true)
if [[ -z "$refs" ]]; then
    printf 'workflow-skeleton: workflow не вызывает ни одного .github/scripts/*.sh\n' >&2
    exit 1
fi

while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    name=${ref#bash .github/scripts/}
    path="$REPO_ROOT/.github/scripts/$name"
    if [[ ! -e "$path" ]]; then
        printf 'workflow-skeleton: workflow вызывает %s, но файла %s нет\n' "$name" "$path" >&2
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

printf 'структура workflow и вызовы скриптов в порядке\n'
