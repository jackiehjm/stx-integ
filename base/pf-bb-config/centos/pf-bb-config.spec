%global git_sha    945712e8876be2003f2f31de70353c48501519fa

Summary:  PF BBDEV (baseband device) Configuration Application.
Name: pf-bb-config
Version: 21.3
Release: 0%{?_tis_dist}.%{tis_patch_ver}
License: Apache-2.0
Group: base
Packager: Wind River <info@windriver.com>
URL: https://github.com/intel/pf-bb-config/releases/tag/v21.3
Source0: %{name}-%{git_sha}.tar.gz
Patch0: Reject-device-configuration-if-not-enabled.patch

BuildRequires: gcc
BuildRequires: inih

%define debug_package %{nil}
%description
The PF BBDEV (baseband device) Configuration Application "pf_bb_config" provides a means to
configure the baseband device at the host-level. The program accesses the configuration
space and sets the various parameters through memory-mapped IO read/writes.

%prep
%setup
%patch0 -p1

%build
make

%install

install -d -m 755 %{buildroot}%{_bindir}
install -d -m 755 %{buildroot}%{_datadir}/pf-bb-config/acc100
install -p -D -m 700 pf_bb_config %{buildroot}%{_bindir}/pf_bb_config
install -p -D -m 700 acc100/acc100_config_vf_5g.cfg %{buildroot}%{_datadir}/pf-bb-config/acc100/acc100_config_vf_5g.cfg
install -p -D -m 644 README.md %{buildroot}%{_datadir}/pf-bb-config/README.md

%clean
rm -rf $RPM_BUILD_ROOT

%files
%defattr(-,root,root,-)
%{_bindir}/*
%{_datadir}/*
