#!/bin/bash

set -euo pipefail

# ログ出力関数スクリプト読み込み
source "$(dirname "$0")/logger.sh"

# メイン処理
main() {
    log_info "========== Start ChangeSet Summarization =========="

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
        if [ -z "${!var:-}" ]; then
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
    # テキストレポート初期化
    # ---------------------------------------------------------------
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')

    # 統計カウンター初期化
    local total_stacks=0
    local total_add=0
    local total_modify=0
    local total_remove=0
    local total_delete=0

    # テキストレポート生成
    local report_file="changeset-summary.txt"

    cat > "$report_file" << EOF
================================================================================
CloudFormation ChangeSet Summary Report
================================================================================
Commit:    ${COMMIT_HASH}
Timestamp: ${timestamp}
================================================================================

EOF

    # ---------------------------------------------------------------
    # 各Stackの変更セット確認
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

        # exec_flg が delete の場合にレポートに記載する
        if [ "$exec_flg" == "delete" ]; then

            # 対象Stackが存在するかを確認
            log_info "Stack '${stack_name}' is marked for deletion."
            if aws cloudformation describe-stacks --stack-name "$stack_name" &>/dev/null; then
                log_info "Stack '${stack_name}' still exists."
                total_delete=$((total_delete + 1))
            fi

            # レポートに削除対象として記載
            echo "Stack: ${stack_name}" >> "$report_file"
            echo "  Status: DELETE_TARGET" >> "$report_file"
            echo "  Note: This stack is marked for deletion (exec_flg=delete)." >> "$report_file"
            echo "        Run 'aws cloudformation delete-stack' in the DeployStage to delete it." >> "$report_file"
            echo "" >> "$report_file"

            continue
        fi

        # exec_flg が apply 以外の場合には処理をスキップ
        if [ "$exec_flg" != "apply" ]; then
            log_info "Skipping stack '${stack_name}' because exec_flg is not apply."
            continue
        fi

        log_info "Analyzing stack: ${stack_name}"

        # ChangeSetが存在するか確認
        # ChangeSetが存在しない場合には次Stackに遷移 (「変更なし」の変更セットは前段で削除されている)
        local changeset_name="${stack_name}-changeset-${COMMIT_HASH}"
        local tmp_json="/tmp/${changeset_name}.json"

        if ! aws cloudformation describe-change-set \
            --change-set-name "$changeset_name" \
            --stack-name "$stack_name" \
            --output json > "$tmp_json" 2>/dev/null; then
            log_warn "No ChangeSet found for '${stack_name}'. Skipping Report..."
            continue
        fi

        total_stacks=$((total_stacks + 1))

        # 変更カウント
        local status add_count modify_count remove_count
        read -r status add_count modify_count remove_count < <(jq -r '
            [
                (.Status // "UNKNOWN"),
                ([.Changes[]? | select(.ResourceChange.Action == "Add")] | length),
                ([.Changes[]? | select(.ResourceChange.Action == "Modify")] | length),
                ([.Changes[]? | select(.ResourceChange.Action == "Remove")] | length)
            ] | @tsv
        ' "$tmp_json")

        # 変更セットが正常完了している場合のみ全体の合計に加算
        if [ "$status" == "CREATE_COMPLETE" ]; then
            total_add=$((total_add + add_count))
            total_modify=$((total_modify + modify_count))
            total_remove=$((total_remove + remove_count))
        fi

        # 変更がある場合のみレポートに追加
        local total_changes=$((add_count + modify_count + remove_count))
        if [ "$total_changes" -gt 0 ]; then
            echo "Stack: ${stack_name}" >> "$report_file"
            echo "  Status: ${status}" >> "$report_file"
            echo "  Changes:" >> "$report_file"
            echo "    Add:    ${add_count}" >> "$report_file"
            echo "    Modify: ${modify_count}" >> "$report_file"
            echo "    Remove: ${remove_count}" >> "$report_file"

            # 変更詳細を追加
            if [ "$status" == "CREATE_COMPLETE" ]; then
                echo "  Resources:" >> "$report_file"
                jq -r '.Changes[]? | "    - [\(.ResourceChange.Action)] \(.ResourceChange.LogicalResourceId) (\(.ResourceChange.ResourceType))"' "$tmp_json" >> "$report_file"
            fi
            echo "" >> "$report_file"
        fi

    done < "$tmp_list"

    # 変更がない場合のメッセージ
    if [ "$((total_add + total_modify + total_remove + total_delete))" -eq 0 ]; then
        cat >> "$report_file" << EOF
No changes detected in any stacks.
All stacks are up-to-date.
EOF
    fi

    # サマリーフッター
    cat >> "$report_file" << EOF
================================================================================
Summary
================================================================================
Total Changed stacks: ${total_stacks}
Total Deletion stacks: ${total_delete}
Total Changes:
  Add:    ${total_add}
  Modify: ${total_modify}
  Remove: ${total_remove}
================================================================================
EOF

    log_info "Report generated: ${report_file}"
    local s3_key="changeset-reports/${COMMIT_HASH}/changeset-summary.txt"
    local s3_url="s3://${ARTIFACT_BUCKET_NAME}/${s3_key}"
    log_info "Uploading report to S3: ${s3_url}"
    aws s3 cp "$report_file" "$s3_url" --quiet
    log_info "========== ChangeSet Summarization Finished =========="
}

# スクリプト実行
main
exit $?