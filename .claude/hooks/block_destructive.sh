#!/usr/bin/env bash
set -euo pipefail

INPUT="$(cat)"
COMMAND="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"

# 归一化空白，方便匹配
CMD_NORM="$(printf '%s' "$COMMAND" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"

deny() {
  local reason="$1"
  jq -n --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# 1) 直接 rm / sudo rm
if echo "$CMD_NORM" | grep -Eiq '(^|[;&|[:space:]])(sudo[[:space:]]+)?rm([[:space:]]|$)'; then
  deny "Blocked rm command. Delete manually after review."
fi

# 2) find -delete
if echo "$CMD_NORM" | grep -Eiq '(^|[;&|[:space:]])find([[:space:]].*)?-delete([[:space:]]|$)'; then
  deny "Blocked find -delete."
fi

# 3) 常见删除/清空工具
if echo "$CMD_NORM" | grep -Eiq '(^|[;&|[:space:]])(shred|unlink)([[:space:]]|$)'; then
  deny "Blocked destructive file deletion tool."
fi

# 4) 危险 git 清理
if echo "$CMD_NORM" | grep -Eiq '(^|[;&|[:space:]])git([[:space:]]+clean)([[:space:]].*)?([[:space:]]-f.*-d|-d.*-f)'; then
  deny "Blocked git clean destructive operation."
fi

# 默认放行
exit 0