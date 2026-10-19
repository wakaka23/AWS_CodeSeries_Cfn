#!/bin/bash

# 実行コマンドが失敗した場合、または未定義の変数を使用した場合はスクリプトを終了する
set -euo pipefail

# ログ出力関数スクリプト読み込み
source "$(dirname "$0")/logger.sh"

# メイン処理
main() {
    log_info "========== Start Change Set Creation =========="

    # ---------------------------------------------------------------
    # 環境変数チェック
    # ---------------------------------------------------------------
    local required_vars=(
        "ENV_NAME"
        "ARTIFACT_BUCKET_NAME"
        "CODE_SRC_DIR"
        "REGIONAL_DOMAIN_NAME"
        "RELEASE_OR_ROLLBACK"
        "COMMIT_HASH"
    )
    for var in "${required_vars[@]}"; do
        if [[ ! -v "$var" || -z "${!var}" ]]; then
            log_error "Environment variable ${var} has not been set..."
            exit 1
        fi
    done

    # ---------------------------------------------------------------
    # リリース処理 or 切り戻し処理
    # ---------------------------------------------------------------
    local stack_list="./${CODE_SRC_DIR}/lists/stack-list.txt"
    local tmp_list="/tmp/stack-list-sorted.txt"

    if [ "${RELEASE_OR_ROLLBACK}" == "Rollback" ]; then
        log_info "Mode: Rollback (Processing in reverse order)"
        cat "${stack_list}" | tr -d '\r' | sed -e '$a\' | tac > "$tmp_list"
    else
        log_info "Mode: Release (Processing in normal order)"
        cat "${stack_list}" | tr -d '\r' | sed -e '$a\' > "$tmp_list"
    fi

    # ---------------------------------------------------------------
    # 変更セット作成処理
    # ---------------------------------------------------------------

    # ファイルリストを1行ずつ読み込んで処理
    while IFS=, read -r stack_name template_file parameter_file exec_flg || [[ -n "$stack_name" ]]; do

        # すべての変数の前後スペースと改行をトリミング
        stack_name=$(echo "$stack_name" | xargs)
        template_file=$(echo "$template_file" | xargs)
        parameter_file=$(echo "$parameter_file" | xargs)
        exec_flg=$(echo "$exec_flg" | xargs)

        # 環境変数展開 (txtファイルで定義されている${Stage}などの変数を実際の値に置換)
        stack_name="${stack_name//\$\{Stage\}/${ENV_NAME}}"

        # 空行とコメント行をスキップ
        [[ -z "$stack_name" || "$stack_name" =~ ^[[:space:]]*# ]] && continue

        # exec_flg が apply 以外の場合には処理をスキップ
        if [ "$exec_flg" != "apply" ]; then
            log_info "Skipping stack '${stack_name}' because exec_flg is not apply."
            continue
        fi

        log_info "Processing stack: ${stack_name}"
        local change_set_name="${stack_name}-changeset-${COMMIT_HASH}"
        local template_url="https://${REGIONAL_DOMAIN_NAME}/source/${COMMIT_HASH}/${CODE_SRC_DIR}/${template_file}"
        local parameters_path="file://./${CODE_SRC_DIR}/params/${ENV_NAME}/${parameter_file}"

        # 対象StackのStatus確認 (REVIEW_IN_PROGRESS/ROLLBACK_COMPLETE/UPDATE_ROLLBACK_COMPLETE/CREATE_COMPLETE/UPDATE_COMPLETE or NOT_EXISTS)
        local current_status
        current_status=$(aws cloudformation describe-stacks \
            --stack-name "$stack_name" \
            --query 'Stacks[0].StackStatus' \
            --output text 2>/dev/null || echo "NOT_EXISTS")

        # ROLLBACK_COMPLETE/DELETE_FAILED の場合にはStackを削除しないと先に進めないため、削除処理
        if [[ "$current_status" == "ROLLBACK_COMPLETE" || "$current_status" == "DELETE_FAILED" ]]; then
            log_warn "Stack '${stack_name}' is in ${current_status} status. Deleting the stack to recreate it..."

            # スタック削除命令
            aws cloudformation delete-stack --stack-name "$stack_name"

            # 完全に削除されるまで待機
            log_info "Waiting for stack '${stack_name}' to be deleted."
            if ! aws cloudformation wait stack-delete-complete --stack-name "$stack_name"; then
                log_error "Failed to delete stack '${stack_name}'."
                exit 1
            fi

            log_info "Stack '${stack_name}' deleted successfully."

            # ステータスを NOT_EXISTS に書き換えることで、後続の処理でchange_set_type="CREATE"とする
            current_status="NOT_EXISTS"
        fi

        # スタックの存在確認を行い、変更セットのタイプを決定
        local change_set_type="UPDATE"
        if [ "$current_status" = "NOT_EXISTS" ] || [ "$current_status" = "REVIEW_IN_PROGRESS" ]; then
            change_set_type="CREATE"
        fi

        # 既存の同名変更セットが存在する場合は削除
        if aws cloudformation describe-change-set --change-set-name "$change_set_name" --stack-name "$stack_name" &>/dev/null; then
            log_info "Deleting existing change set '${change_set_name}'..."
            aws cloudformation delete-change-set \
                --change-set-name "$change_set_name" \
                --stack-name "$stack_name" &>/dev/null || true
            sleep 10
        fi

        # 変更セット作成処理実行
        log_info "Creating change set '${change_set_name}' (${change_set_type})..."
        aws cloudformation create-change-set \
            --stack-name "$stack_name" \
            --template-url "$template_url" \
            --parameters "$parameters_path" \
            --change-set-name "$change_set_name" \
            --change-set-type "$change_set_type" \
            --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND >/dev/null

        # 変更セットの作成完了待機
        log_info "Waiting for change set '${change_set_name}' to be created..."
        if ! aws cloudformation wait change-set-create-complete --change-set-name "$change_set_name" --stack-name "$stack_name" &>/dev/null; then

            log_warn "Wait command failed for '${change_set_name}'. Describing status..."

            local reason
            reason=$(aws cloudformation describe-change-set --change-set-name "$change_set_name" --stack-name "$stack_name" --query 'StatusReason' --output text 2>/dev/null)

            # 「変更なし」の場合は正常スキップ (変更セットを削除して次へ)
            if [[ "$reason" == *"didn't contain changes"* || "$reason" == *"No updates are to be performed"* ]]; then
                log_info "No changes detected for '${stack_name}'. Cleaning up empty change set."
                aws cloudformation delete-change-set --stack-name "$stack_name" --change-set-name "$change_set_name" &>/dev/null
                continue
            else
                log_error "Change set creation failed for stack '${stack_name}'. Reason: ${reason}"
                exit 1
            fi
        else
            log_info "Change set for stack '${stack_name}' created successfully."
        fi

    done < "$tmp_list"

    log_info "========== Change Set Creation Finished =========="
}

# スクリプト実行
main
exit $?