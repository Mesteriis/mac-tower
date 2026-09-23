#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"

ruby - "$project_root/homeassistant/blueprints/automation/mactower/notifications.yaml" <<'RUBY'
require "yaml"

class InputReference
  attr_reader :value
  def init_with(coder)
    @value = coder.scalar
  end
end

Psych.add_tag("!input", InputReference)
path = ARGV.fetch(0)
source = File.read(path, encoding: "UTF-8")
document = YAML.safe_load(source, permitted_classes: [InputReference], aliases: false)
abort "wrong domain" unless document.dig("blueprint", "domain") == "automation"
inputs = document.dig("blueprint", "input") || {}
abort "missing inputs" unless %w[panel_topic ack_topic notify_action].all? { |key| inputs.key?(key) }
abort "missing mqtt trigger" unless source.include?("trigger: mqtt")
abort "missing action trigger" unless source.include?("mobile_app_notification_action")
abort "retained ack" if source.match?(/retain:\s*true/)
abort "unsafe command" if source.match?(/shell_command|command_line|rest_command/)
abort "missing qos" unless source.match?(/qos:\s*1/)
abort "missing UUID guard" unless source.include?("[0-9a-fA-F-]{36}")
abort "missing stable tag" unless source.include?("trigger.payload_json.event_id")
puts "PASS: Home Assistant notification blueprint contract."
RUBY
