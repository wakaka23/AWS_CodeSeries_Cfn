#!/bin/bash

# 実行コマンドが失敗した場合、または未定義の変数を使用した場合はスクリプトを終了する
set -euo pipefail

# ログ出力関数スクリプト読み込み
source "$(dirname "$0")/logger.sh"

# メイン処理
main() {
    log_info "========== Start Rollback PR Automation =========="

    # ---------------------------------------------------------------
    # 環境変数チェック
    # ---------------------------------------------------------------
    local required_vars=(
        "REPOSITORY_NAME"
        "CODE_SRC_DIR"
        "TARGET_BRANCH"
    )
    for var in "${required_vars[@]}"; do
        if [[ ! -v "$var" || -z "${!var}" ]]; then
            log_error "Environment variable ${var} has not been set..."
            exit 1
        fi
    done

    # ---------------------------------------------------------------
    # 各種コミット・ブランチ情報の算出
    # ---------------------------------------------------------------
    local current_commit
    local prev_tag
    local prev_commit
    local rollback_branch

    current_commit=$(git rev-parse HEAD)
    prev_tag=$(git describe --tags --abbrev=0 HEAD~1 2>/dev/null) || { log_error "Exit as previous tag cannot be detected"; exit 1; }
    prev_commit=$(git rev-parse "${prev_tag}")
    rollback_branch="rollback/${CODEBUILD_SOURCE_VERSION}"

    log_info "Current Tag: ${CODEBUILD_SOURCE_VERSION} (${current_commit})"
    log_info "Previous Tag: ${prev_tag} (${prev_commit})"
    log_info "Rollback Branch: ${rollback_branch}"

    # ---------------------------------------------------------------
    # Git基本設定
    # ---------------------------------------------------------------
    git config --global user.email "devops-automation@test.sre.com"
    git config --global user.name "DevOps-Automation"

    log_info "Creating and checking out rollback branch: ${rollback_branch}"
    git checkout -b "${rollback_branch}" &>/dev/null

    # ---------------------------------------------------------------
    # 差分ファイルの解析と切り戻し
    # ---------------------------------------------------------------
    log_info "Analyzing file differences and restoring..."

    # 【既存テンプレートの切り戻し】前回のコミットから変更(M)があったYAML,JSONを検知して前回の状態に復元
    while read -r file; do
        [[ -z "$file" ]] && continue
        log_info "Restoring modified file: ${file}"
        git restore --source="${prev_commit}" "${file}"
    done < <(git diff --name-only --diff-filter=M "${prev_commit}" "${current_commit}" | grep -E '\.(yaml|json)$' | grep -v 'buildscripts/' || true)

    # 【新規の削除】前回のコミットから新規追加(A)されたYamlを特定して削除＋stack-list.txtを更新
    while read -r file; do
        [[ -z "$file" ]] && continue
        log_info "Processing deletion for newly added YAML: ${file}"

        local filename
        local target_list
        filename=$(basename "${file}")
        target_list="${CODE_SRC_DIR}/lists/stack-list.txt"

        if grep -q "${filename}" "${target_list}"; then
            log_info "Updating stack list exec_flag to delete: ${filename}"
            sed -i -E "/${filename}/s/apply/delete/" "${target_list}"
        else
            log_info "Skip updating stack list: ${filename} is not in the list."
        fi

        log_info "Deleting newly added YAML: ${file}"
        rm -f "${file}"
    done < <(git diff --name-only --diff-filter=A "${prev_commit}" "${current_commit}" | grep '\.yaml$' | grep -v 'buildscripts/' || true)

    # 【新規の削除】前回のコミットから新規追加(A)されたJsonを特定して削除
    while read -r file; do
        [[ -z "$file" ]] && continue
        log_info "Deleting newly added JSON: ${file}"
        rm -f "${file}"
    done < <(git diff --name-only --diff-filter=A "${prev_commit}" "${current_commit}" | grep '\.json$' || true)

    # ---------------------------------------------------------------
    # 変更コミット & Push & プルリクエスト作成処理
    # ---------------------------------------------------------------
    if ! git diff --quiet || ! git diff --cached --quiet; then
        log_info "Changes detected. Committing and pushing to origin..."
        git add .
        git commit -m "rollback: restore to ${prev_tag}" &>/dev/null

        git config --global credential.helper '!aws codecommit credential-helper $@'
        git config --global credential.UseHttpPath true

        if ! git push -u origin "${rollback_branch}" &>/dev/null; then
            log_error "Failed to push rollback branch to origin."
            exit 1
        fi

        log_info "Opening automated pull request to CodeCommit..."
        if ! aws codecommit create-pull-request \
            --title "${CODEBUILD_SOURCE_VERSION} 切り戻し用PR" \
            --description "本番環境で問題が発生し切り戻しが必要になった場合には、このPRをマージしてパイプラインを実行してください。${prev_tag}の断面に復元します。" \
            --targets repositoryName="${REPOSITORY_NAME}",sourceReference="${rollback_branch}",destinationReference="${TARGET_BRANCH}" >/dev/null; then
            log_error "Failed to create pull request."
            exit 1
        fi
        log_info "Rollback pull request created successfully."
    else
        log_info "No changes detected. Skipping rollback PR creation."
    fi

    log_info "========== Rollback PR Automation Finished =========="
}

# スクリプト実行
main
exit $?