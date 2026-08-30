Name: t2-coreos-dracut
Version: 1
Release: 1%{?dist}
Summary: Fedora CoreOS sysusers integration for the T2 initramfs
License: MIT
BuildArch: noarch

%description
Makes dracut apply Fedora CoreOS static sysusers definitions before generating initramfs account files.

%install
install -Dpm0755 %{_sourcedir}/module-setup.sh \
    "%{buildroot}%{_prefix}/lib/dracut/modules.d/50coreos-sysusers/module-setup.sh"

%files
%{_prefix}/lib/dracut/modules.d/50coreos-sysusers/module-setup.sh
