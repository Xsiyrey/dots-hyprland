# This script is meant to be sourced.
# It's not for directly running.

# shellcheck shell=bash

#####################################################################################
# MISC (For dots/.config/* but not quickshell, not fish, not Hyprland, not fontconfig)
case "${SKIP_MISCCONF}" in
  true) true;;
  *)
    for i in $(find dots/.config/ -mindepth 1 -maxdepth 1 ! -name 'quickshell' ! -name 'fish' ! -name 'hypr' ! -name 'fontconfig' -exec basename {} \;); do
#      i="dots/.config/$i"
      echo "[$0]: Found target: dots/.config/$i"
      if [ -d "dots/.config/$i" ];then install_dir__sync "dots/.config/$i" "$XDG_CONFIG_HOME/$i"
      elif [ -f "dots/.config/$i" ];then install_file "dots/.config/$i" "$XDG_CONFIG_HOME/$i"
      fi
    done
    install_dir "dots/.local/share/konsole" "${XDG_DATA_HOME}"/konsole
    ;;
esac

case "${SKIP_QUICKSHELL}" in
  true) true;;
  *)
     # Should overwriting the whole directory not only ~/.config/quickshell/ii/ cuz https://github.com/end-4/dots-hyprland/issues/2294#issuecomment-3448671064
    install_dir__sync dots/.config/quickshell "$XDG_CONFIG_HOME"/quickshell
    ;;
esac

case "${SKIP_FISH}" in
  true) true;;
  *)
    install_dir__sync_exclude dots/.config/fish "$XDG_CONFIG_HOME"/fish "conf.d"
    ;;
esac

case "${SKIP_FONTCONFIG}" in
  true) true;;
  *)
    case "$FONTSET_DIR_NAME" in
      "") install_dir__sync dots/.config/fontconfig "$XDG_CONFIG_HOME"/fontconfig ;;
      *) install_dir__sync dots-extra/fontsets/$FONTSET_DIR_NAME "$XDG_CONFIG_HOME"/fontconfig ;;
    esac;;
esac

# For Hyprland
case "${SKIP_HYPRLAND}" in
  true) true;;
  *)
    install_dir__sync dots/.config/hypr/hyprland "$XDG_CONFIG_HOME"/hypr/hyprland
    if [ -f "${XDG_CONFIG_HOME}/hypr/hyprland.conf" ]; then
      mv "${XDG_CONFIG_HOME}/hypr/hyprland.conf" "${XDG_CONFIG_HOME}/hypr/hyprland.conf.old" # disable old config
      echo 'hyprland.conf has been renamed to hyprland.conf.old. This is to allow the new lua config to load.'
    fi
    for i in hyprlock.conf ; do
      install_file__auto_backup "dots/.config/hypr/$i" "${XDG_CONFIG_HOME}/hypr/$i"
    done
    for i in hyprland.lua ; do
      case "${SKIP_HYPRLAND_ENTRY}" in
        true) true;;
        *) install_file "dots/.config/hypr/$i" "${XDG_CONFIG_HOME}/hypr/$i" ;;
      esac
    done
    for i in hypridle.conf ; do
      if [[ "${INSTALL_VIA_NIX}" == true ]]; then
        install_file__auto_backup "dots-extra/via-nix/$i" "${XDG_CONFIG_HOME}/hypr/$i"
      else
        install_file__auto_backup "dots/.config/hypr/$i" "${XDG_CONFIG_HOME}/hypr/$i"
      fi
    done
    if [ "$OS_GROUP_ID" = "fedora" ];then
      v bash -c "printf \"# For fedora to setup polkit\nexec-once = /usr/libexec/kf6/polkit-kde-authentication-agent-1\n\" >> ${XDG_CONFIG_HOME}/hypr/hyprland/execs.conf"
    fi

    install_dir__ignore_existing "dots/.config/hypr/custom" "${XDG_CONFIG_HOME}/hypr/custom"

    # Multi-monitor workspace setup
    # Detect connected monitors via DRM sysfs (works without a running compositor)
    monitor_entries=()
    for drm_dir in /sys/class/drm/card*-*/; do
      [[ -d "$drm_dir" ]] || continue
      conn_status=$(cat "${drm_dir}status" 2>/dev/null || true)
      [[ "$conn_status" == "connected" ]] || continue
      conn_name=$(basename "$drm_dir" | sed 's/^card[0-9]*-//')
      preferred_mode=""
      if [[ -f "${drm_dir}modes" ]]; then
        preferred_mode=$(head -1 "${drm_dir}modes" 2>/dev/null || true)
      fi
      product_name=""
      if [[ -f "${drm_dir}edid" ]] && command -v edid-decode &>/dev/null; then
        product_name=$(edid-decode "${drm_dir}edid" 2>/dev/null | grep -oP "Display Product Name: '\\K[^']*" | head -1 || true)
      fi
      monitor_entries+=("${conn_name}|${preferred_mode}|${product_name}")
    done

    if [[ ${#monitor_entries[@]} -ge 2 ]]; then
      printf "\n${STY_CYAN}${STY_BOLD}Multi-monitor setup detected:${STY_RST}\n"
      i=1
      for entry in "${monitor_entries[@]}"; do
        name="${entry%%|*}"
        rest="${entry#*|}"
        mode="${rest%%|*}"
        desc="${rest#*|}"
        if [[ -n "$desc" ]]; then
          printf "${STY_CYAN}  %d) %s — %s (%s)${STY_RST}\n" "$i" "$name" "$desc" "$mode"
        else
          printf "${STY_CYAN}  %d) %s (%s)${STY_RST}\n" "$i" "$name" "$mode"
        fi
        i=$((i + 1))
      done
      printf "\n${STY_BLUE}${STY_BOLD}Which monitor should be your primary (workspace 1)?${STY_RST}\n"
      printf "${STY_BLUE}  Enter number (1-%d), or s = skip: ${STY_RST}" "${#monitor_entries[@]}"
      read -r choice
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#monitor_entries[@]} )); then
        primary_entry="${monitor_entries[$((choice-1))]}"
        primary_name="${primary_entry%%|*}"
        custom_general="${XDG_CONFIG_HOME}/hypr/custom/general.lua"
        mkdir -p "$(dirname "$custom_general")"
        touch "$custom_general"

        # Drop a previous installer block, including the blank line before it.
        # Everything else in general.lua stays.
        awk '
          /^-- Multi-monitor workspace assignment \(auto-generated by installer\)$/ {
            if (!(have_prev && prev == "")) {
              if (have_prev) print prev
            }
            have_prev = 0
            skip = 1
            next
          }
          skip {
            if ($0 ~ /^-- End multi-monitor workspace assignment$/) skip = 0
            next
          }
          {
            if (have_prev) print prev
            prev = $0
            have_prev = 1
          }
          END { if (have_prev) print prev }
        ' "$custom_general" > "${custom_general}.tmp"
        mv "${custom_general}.tmp" "$custom_general"

        # Primary monitor gets workspace 1; the others get 2, 3, ...
        ws=2
        {
          printf '\n-- Multi-monitor workspace assignment (auto-generated by installer)\n'
          lua_name=${primary_name//\\/\\\\}
          lua_name=${lua_name//\"/\\\"}
          printf 'hl.workspace_rule({ workspace = "1", monitor = "%s", default = true })\n' "$lua_name"
          for entry in "${monitor_entries[@]}"; do
            name="${entry%%|*}"
            if [[ "$name" != "$primary_name" ]]; then
              lua_name=${name//\\/\\\\}
              lua_name=${lua_name//\"/\\\"}
              printf 'hl.workspace_rule({ workspace = "%d", monitor = "%s", default = true })\n' "$ws" "$lua_name"
              ws=$((ws + 1))
            fi
          done
          printf '%s\n' '-- End multi-monitor workspace assignment'
        } >> "$custom_general"

        printf "${STY_GREEN}[$0]: Workspace 1 assigned to %s${STY_RST}\n" "$primary_name"
      else
        printf "${STY_BLUE}Skipping monitor workspace setup.${STY_RST}\n"
      fi
    fi
    ;;
esac

install_file "dots/.local/share/icons/illogical-impulse.svg" "${XDG_DATA_HOME}"/icons/illogical-impulse.svg
