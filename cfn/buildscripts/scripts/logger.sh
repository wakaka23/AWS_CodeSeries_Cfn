#!/bin/bash

_log() {
    # 関数の引数をローカル変数に格納
    # 第1引数(ログレベル)を取り除き、残りをメッセージとして扱う
    local level="$1"
    local script_info="$2"
    shift 2
    local message="$@"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # フォーマットして標準エラー出力へ出力 (>&2)
    echo "[${timestamp}] [${level}] [${script_info}] ${message}" >&2
}

# ログレベルごとのラッパー関数
# 情報メッセージ
log_info() {
    # BASH_SOURCE[1] は呼び出し元ファイル名、BASH_LINENO[0] は呼び出し元の行番号
    local script_info="${BASH_SOURCE[1]##*/}:${BASH_LINENO[0]}"
    # 取得した情報とメッセージを内部関数に連携
    _log "INFO" "$script_info" "$@"
}

log_warn() {
    # BASH_SOURCE[1] は呼び出し元ファイル名、BASH_LINENO[0] は呼び出し元の行番号
    local script_info="${BASH_SOURCE[1]##*/}:${BASH_LINENO[0]}"
    # 取得した情報とメッセージを内部関数に連携
    _log "WARN" "$script_info" "$@"
}

log_error() {
    # BASH_SOURCE[1] は呼び出し元ファイル名、BASH_LINENO[0] は呼び出し元の行番号
    local script_info="${BASH_SOURCE[1]##*/}:${BASH_LINENO[0]}"
    # 取得した情報とメッセージを内部関数に連携
    _log "ERROR" "$script_info" "$@"
}