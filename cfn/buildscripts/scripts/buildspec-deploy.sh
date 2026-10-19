#!/bin/bash

# 実行コマンドが失敗した場合、または未定義の変数を使用した場合はスクリプトを終了する
set -euo pipefail

# ログ出力関数スクリプト読み込み
source "$(dirname "$0")/logger.sh"

# メイン処理
main() {
    log_info "========== Start Stack Deployment =========="

    # ---------------------------------------------------------------
    # 環境変数チェック
    # ---------------------------------------------------------------
    local required_vars=(
        "ENV_NAME"
        "ARTIFACT_BUCKET_NAME"
        "CODE_SRC_DIR"
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
    # 変更セット実行処理
    # ---------------------------------------------------------------

    # ファイルリストを1行ずつ読み込んで処理
    while IFS=, read -r stack_name template_file parameter_file exec_flg || [[ -n "$stack_name" ]]; do

        # すべての変数の前後スペースと改行をトリミング
        stack_name=$(echo "$stack_name" | xargs)
        template_file=$(echo "$template_file" | xargs)
        parameter_file=$(echo "$parameter_file" | xargs)
        exec_flg=$(echo "$exec_flg" | xargs)

        # 環境変数展開 (${Stage}変数を実際の値に置換)
        stack_name="${stack_name//\$\{Stage\}/${ENV_NAME}}"

        # 空行とコメント行をスキップ
        [[ -z "$stack_name" || "$stack_name" =~ ^[[:space:]]*# ]] && continue

        # exec_flg が delete の場合は削除処理
        if [ "$exec_flg" == "delete" ]; then

            log_info "Processing stack: ${stack_name}"

            # スタックが存在するか確認してから削除
            if aws cloudformation describe-stacks --stack-name "$stack_name" &>/dev/null; then
                log_warn "Deleting stack '${stack_name}' because exec_flg is delete."
                aws cloudformation delete-stack --stack-name "$stack_name"
                aws cloudformation wait stack-delete-complete --stack-name "$stack_name"
                log_info "Stack '${stack_name}' deleted successfully."
            else
                log_info "Stack '${stack_name}' does not exist, skipping deletion."
            fi
            continue
        fi

        # exec_flg が apply 以外の場合には処理をスキップ
        if [ "$exec_flg" != "apply" ]; then
            log_info "Skipping stack '${stack_name}' because exec_flg is not apply."
            continue
        fi

        log_info "Processing stack: ${stack_name}"
        local change_set_name="${stack_name}-changeset-${COMMIT_HASH}"

        # 対象StackのStatus確認
        local stack_status
        stack_status=$(aws cloudformation describe-stacks \
            --stack-name "$stack_name" \
            --query 'Stacks[0].StackStatus' \
            --output text)

        # 実行対象の変更セットの状態を確認
        local exec_status
        exec_status=$(aws cloudformation describe-change-set \
            --change-set-name "$change_set_name" \
            --stack-name "$stack_name" \
            --query 'ExecutionStatus' \
            --output text 2>/dev/null) || exec_status="NOT_FOUND"

        # 変更セットが存在しない or 存在するがAVAILABLEでない場合にはスキップ
        if [ "$exec_status" != "AVAILABLE" ]; then
            log_info "No executable change set '${change_set_name}' found (Status: ${exec_status}). Skipping."
            continue
        fi

        # 変更セット実行
        log_info "Found change set '${change_set_name}'. Executing..."
        if ! aws cloudformation execute-change-set --stack-name "$stack_name" --change-set-name "$change_set_name"; then
            log_error "Failed to execute change set '${change_set_name}'."
            exit 1
        fi

        # 対象StackのStatusに応じて待機コマンド切り替え
        if [ "$stack_status" = "REVIEW_IN_PROGRESS" ]; then
            log_info "Waiting for stack creation to complete..."
            if ! aws cloudformation wait stack-create-complete --stack-name "$stack_name"; then
                log_error "Stack creation failed for '${stack_name}'. Please check the AWS CloudFormation console for event logs."
                exit 1
            fi
            log_info "Stack '${stack_name}' created successfully."
        else
            log_info "Waiting for stack update to complete..."
            if ! aws cloudformation wait stack-update-complete --stack-name "$stack_name"; then
                log_error "Stack update failed for '${stack_name}'. Rollback may be in progress. Please check the AWS CloudFormation console."
                exit 1
            fi
            log_info "Stack '${stack_name}' updated successfully."
        fi

    done < "$tmp_list"

    log_info "========== Stack Deployment Finished =========="
}

# スクリプト実行
main
exit $?