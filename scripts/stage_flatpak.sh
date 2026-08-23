#!/usr/bin/env bash
# scripts/stage_flatpak.sh — Flatpak runtime and the Flathub remote.
# Follows https://flathub.org/setup/Ubuntu. No PPA is involved; both packages
# come from the distribution. The flatpak package itself is in PACKAGES_APT.

stage_flatpak() {
  [[ "$OS_KIND" == linux ]] || { ok "flatpak is a Linux concern"; return 0; }

  command -v flatpak >/dev/null 2>&1 || {
    warn "flatpak is not installed; the package stage owns it"
    return 0
  }

  # The GNOME Software plugin is what surfaces Flathub applications in the
  # desktop store. From 23.10 that store is App Center, and the plugin brings a
  # second, deb-packaged Software app alongside it. Treated as a GUI app so the
  # same SKIP_ convention as LibreOffice and Claude Desktop applies.
  local desktop_pkg desktop_added=0
  for desktop_pkg in "${PACKAGES_APT_FLATPAK_DESKTOP[@]}"; do
    if apt_gui_app_wanted "$desktop_pkg" "${SKIP_FLATPAK_DESKTOP:-}"; then
      if apt-cache show "$desktop_pkg" >/dev/null 2>&1; then
        info "installing $desktop_pkg…"
        if sudo "${APT_ENV[@]}" "$PKGMGR" install -y "$desktop_pkg"; then
          desktop_added=1
        else
          warn "could not install $desktop_pkg"
        fi
      else
        warn "apt: $desktop_pkg is not in this repository"
      fi
    elif pkg_installed "$desktop_pkg"; then
      ok "$desktop_pkg already installed"
    else
      ok "$desktop_pkg skipped"
    fi
  done

  # `flatpak remotes` omits disabled remotes unless --show-disabled is given, so
  # appearing in the plain listing means present *and* enabled. A remote that is
  # merely present serves nothing, which is why the two are distinguished here.
  local flathub_enabled=0 flathub_known=0
  flatpak remotes --system --columns=name 2>/dev/null \
    | grep -x flathub >/dev/null && flathub_enabled=1
  flatpak remotes --system --show-disabled --columns=name 2>/dev/null \
    | grep -x flathub >/dev/null && flathub_known=1

  # A hand-provisioned host may already carry a per-user remote. Adding the
  # system one as well is harmless but leaves two entries with the same name in
  # different scopes, which is confusing to debug later.
  if flatpak remotes --user --columns=name 2>/dev/null | grep -x flathub >/dev/null; then
    warn "a per-user flathub remote already exists; the system remote below is separate from it"
  fi

  if ((flathub_enabled)); then
    ok "flathub remote already configured"
  elif ((flathub_known)); then
    warn "flathub is configured but disabled — enable it with: sudo flatpak remote-modify --enable flathub"
    return 0
  else
    # --if-not-exists keeps a re-run from failing on an existing remote.
    info "adding the flathub remote…"
    sudo flatpak remote-add --if-not-exists flathub "$FLATHUB_REMOTE_URL" \
      || { warn "could not add the flathub remote"; return 0; }
    flatpak remotes --system --columns=name 2>/dev/null \
      | grep -x flathub >/dev/null \
      && ok "flathub remote added and enabled" \
      || warn "flathub remote did not appear after being added"
  fi

  ((desktop_added)) && \
    warn "log out and back in for the desktop store to show Flathub applications"

  return 0
}
