{ applyPatches
, lib
, fetchFromGitHub
, l4t-xusb-firmware
, realtime ? false
, kernelPatches ? [ ]
, structuredExtraConfig ? { }
, argsOverride ? { }
, buildLinux
, ...
}@args:
buildLinux (args // {
  # See Makefile in kernel source root for VERSION/PATCHLEVEL/SUBLEVEL. See realtime patch for rt version
  version = "5.10.216" + lib.optionalString realtime "-rt108";
  extraMeta.branch = "5.10";

  defconfig = "tegra_defconfig";

  # https://github.com/NixOS/nixpkgs/pull/366004
  # introduced a breaking change that if a module is declared but it is not being used it will fail
  # if you try to suppress each of he errors e.g.
  # REISERFS_FS_SECURITY = lib.mkForce unset; within structuredExtraConfig
  # that list runs to a long 100+ modules so we go back to the previous default and ignore them
  ignoreConfigErrors = true;

  # disabling the dependency on the common-config would seem appropriate as we define our own defconfig
  # however, it seems that some of the settings for e.g. fw loading are only made available there.
  # TODO: a future task could be to set this, disable ignoreConfigErrors and add the needed modules to the
  # structuredExtraConfig below.
  #enableCommonConfig = false;

  # Using applyPatches here since it's not obvious how to append an extra
  # postPatch. This is not very efficient.
  src = applyPatches {
    src = fetchFromGitHub {
      owner = "OE4T";
      repo = "linux-tegra-5.10";
      rev = "4bce4d148ef3ff159ab55c127d8761aeaac5cc28"; # latest on oe4t-patches-l4t-r36.0.ga as of 2024-10-27
      sha256 = "sha256-YCOEGQ943EbrApdVFKs+l+g2XWZ8TvdqRxcK8F9ebo8=";
    };
    # Remove device tree overlays with some incorrect "remote-endpoint" nodes.
    # They are strings, but should be phandles. Otherwise, it fails to compile
    postPatch = ''
      rm \
        nvidia/platform/t19x/galen/kernel-dts/tegra194-p2822-camera-imx185-overlay.dts \
        nvidia/platform/t19x/galen/kernel-dts/tegra194-p2822-camera-dual-imx274-overlay.dts \
        nvidia/platform/t23x/concord/kernel-dts/tegra234-p3737-camera-imx185-overlay.dts \
        nvidia/platform/t23x/concord/kernel-dts/tegra234-p3737-camera-dual-imx274-overlay.dts

      sed -i -e '/imx185-overlay/d' -e '/imx274-overlay/d' \
        nvidia/platform/t19x/galen/kernel-dts/Makefile \
        nvidia/platform/t23x/concord/kernel-dts/Makefile

    '' + lib.optionalString realtime ''
      for p in $(find $PWD/rt-patches -name \*.patch -type f | sort); do
        echo "Applying $p"
        patch -s -p1 < $p
      done
    '';
  };
  autoModules = false;
  features = { }; # TODO: Why is this needed in nixpkgs master (but not NixOS 22.05)?

  # As of 22.11, only kernel configs supplied through kernelPatches
  # can override configs specified in the platforms
  kernelPatches = [
    # if USB_XHCI_TEGRA is built as module, the kernel won't build
    {
      name = "make-USB_XHCI_TEGRA-builtins";
      patch = null;
      extraConfig = ''
        USB_XHCI_TEGRA y
      '';
    }

    # Fix "FAILED: resolved symbol udp_sock"
    # This is caused by having multiple structs of the same name in the BTF output.
    # For example, `bpftool btf dump file vmlinux | grep "STRUCT 'udp_sock'"`
    #   [507] STRUCT 'file' size=256 vlen=22
    #   [121957] STRUCT 'file' size=256 vlen=22
    # Without this patch, resolve_btfids doesn't handle this case and
    # miscounts, leading to the failure. The underlying cause of why we have
    # multiple structs of the same name is still unresolved as of 2023-07-29
    { patch = ./0001-tools-resolve_btfids-Warn-when-having-multiple-IDs-f.patch; }

    # Fix Ethernet "downshifting" (e.g.1000Base-T -> 100Base-T) with realtek
    # PHY used on Xavier NX
    { patch = ./0002-net-phy-realtek-read-actual-speed-on-rtl8211f-to-det.patch; }

    # Lower priority of tegra-se crypto modules since they're slow and flaky
    { patch = ./0003-Lower-priority-of-tegra-se-crypto.patch; }
  ] ++ kernelPatches;

  structuredExtraConfig = with lib.kernel; {
    #  MODPOST modules-only.symvers
    #ERROR: modpost: "xhci_hc_died" [drivers/usb/host/xhci-tegra.ko] undefined!
    #ERROR: modpost: "xhci_hub_status_data" [drivers/usb/host/xhci-tegra.ko] undefined!
    #ERROR: modpost: "xhci_enable_usb3_lpm_timeout" [drivers/usb/host/xhci-tegra.ko] undefined!
    #ERROR: modpost: "xhci_hub_control" [drivers/usb/host/xhci-tegra.ko] undefined!
    #ERROR: modpost: "xhci_get_rhub" [drivers/usb/host/xhci-tegra.ko] undefined!
    #ERROR: modpost: "xhci_urb_enqueue" [drivers/usb/host/xhci-tegra.ko] undefined!
    #ERROR: modpost: "xhci_irq" [drivers/usb/host/xhci-tegra.ko] undefined!
    #USB_XHCI_TEGRA = module;
    USB_XHCI_TEGRA = yes;

    # stage-1 links /lib/firmware to the /nix/store path in the initramfs.
    # However, since it's builtin and not a module, that's too late, since
    # the kernel will have already tried loading!
    EXTRA_FIRMWARE_DIR = freeform "${l4t-xusb-firmware}/lib/firmware";
    EXTRA_FIRMWARE = freeform "nvidia/tegra194/xusb.bin";

    # Override the default CMA_SIZE_MBYTES=32M setting in common-config.nix with the default from tegra_defconfig
    # Otherwise, nvidia's driver craps out
    CMA_SIZE_MBYTES = lib.mkForce (freeform "64");

    ### So nat.service and firewall work ###
    NF_TABLES = module; # This one should probably be in common-config.nix
    # this NFT_NAT is not actually being set. when build with enableCommonConfig = false;
    # and not ignoreConfigErrors = true; it will fail with error about unused option
    # unused means that it wanted to set it as a module, but make oldconfig didn't ask it about that option,
    # so it didn't get a chance to set it.
    NFT_NAT = module;
    NFT_MASQ = module;
    NFT_REJECT = module;
    NFT_COMPAT = module;
    NFT_LOG = module;
    NFT_COUNTER = module;
    # IPv6 is enabled by default and without some of these `firewall.service` will explode.
    IP6_NF_MATCH_AH = module;
    IP6_NF_MATCH_EUI64 = module;
    IP6_NF_MATCH_FRAG = module;
    IP6_NF_MATCH_OPTS = module;
    IP6_NF_MATCH_HL = module;
    IP6_NF_MATCH_IPV6HEADER = module;
    IP6_NF_MATCH_MH = module;
    IP6_NF_MATCH_RPFILTER = module;
    IP6_NF_MATCH_RT = module;
    IP6_NF_MATCH_SRH = module;

    # Needed since mdadm stuff is currently unconditionally included in the initrd
    # This will hopefully get changed, see: https://github.com/NixOS/nixpkgs/pull/183314
    MD = yes;
    BLK_DEV_MD = module;
    MD_LINEAR = module;
    MD_RAID0 = module;
    MD_RAID1 = module;
    MD_RAID10 = module;
    MD_RAID456 = module;
  } // (lib.optionalAttrs realtime {
    PREEMPT_VOLUNTARY = lib.mkForce no; # Disable the one set in common-config.nix
    # These are the options enabled/disabled by scripts/rt-patch.sh
    PREEMPT_RT = yes;
    DEBUG_PREEMPT = no;
    KVM = no;
    CPU_IDLE_TEGRA18X = no;
    CPU_FREQ_GOV_INTERACTIVE = no;
    CPU_FREQ_TIMES = no;
    FAIR_GROUP_SCHED = no;
  }) // structuredExtraConfig;

} // argsOverride)
