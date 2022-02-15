# Copyright (C) 2021-present ScyllaDB
#

#
# SPDX-License-Identifier: AGPL-3.0-or-later
#

#
# * At present this is not very useful for nix-build, just for nix-shell
#
# * IMPORTANT: to avoid using up ungodly amounts of disk space under
#   /nix/store/, make sure the actual build directory is physically
#   outside this tree, and make ./build a symlink to it
#

{
  pkgs ? import (fetchTarball "https://github.com/NixOS/nixpkgs/archive/21.11.tar.gz") {},
  mode ? "release",
  verbose ? false,
  useCcache ? false, # can't get this to work, see https://github.com/NixOS/nixpkgs/issues/49894
  testInputsFrom ? (_: []),
  gitPkg ? (pkgs: pkgs.gitMinimal),
}:

with pkgs; let
  inherit (builtins)
    baseNameOf
    fetchurl
    match
    readFile
    toString
    trace;

  antlr3Patched = antlr3.overrideAttrs (_: {
    patches = [
      (fetchurl {
        url = "https://src.fedoraproject.org/rpms/antlr3/raw/f1bb8d639678047935e1761c3bf3c1c7da8d0f1d/f/0006-antlr3memory.hpp-fix-for-C-20-mode.patch";
      })
    ];
  });
  rapidjsonPatched = rapidjson.overrideAttrs (_: {
    patches = [
      (fetchurl {
        url = "https://src.fedoraproject.org/rpms/rapidjson/raw/48402da9f19d060ffcd40bf2b2e6987212c58b0c/f/rapidjson-1.1.0-c++20.patch";
      })
    ];
  });
  zstdStatic = zstd.override {
    static = true;
    legacySupport = true;
    doCheck = false;
  };

  llvmBundle = llvmPackages_12;

  stdenv =
    if useCcache
    then (overrideCC llvmBundle.stdenv (ccacheWrapper.override { cc = llvmBundle.clang; }))
    else llvmBundle.stdenv;

in stdenv.mkDerivation {
  name = "scylladb";
  nativeBuildInputs = [
    ant
    antlr3Patched
    boost17x.dev
    cmake
    gcc
    (gitPkg pkgs)
    libtool
    llvmBundle.lld
    maven
    ninja
    pkg-config
    python3
    ragel
    stow
    util-linux
  ];
  buildInputs = [
    antlr3Patched
    boost17x
    c-ares
    cryptopp
    fmt
    gmp
    gnutls
    hwloc
    icu
    jsoncpp
    libp11
    libsystemtap
    libtasn1
    libunistring
    libxfs
    libxml2
    libyamlcpp
    lksctp-tools
    lua53Packages.lua
    lz4
    nettle
    numactl
    openssl
    p11-kit
    protobuf
    python3Packages.cassandra-driver
    python3Packages.distro
    python3Packages.psutil
    python3Packages.pyparsing
    python3Packages.pyudev
    python3Packages.pyyaml
    python3Packages.requests
    python3Packages.setuptools
    python3Packages.urwid
    rapidjsonPatched
    snappy
    systemd
    thrift
    valgrind
    xorg.libpciaccess
    xxHash
    zlib
    zstdStatic
  ] ++ (testInputsFrom pkgs);

  src = lib.cleanSourceWith {
    filter = name: type:
      let baseName = baseNameOf (toString name); in
      !((type == "symlink" && baseName == "build") ||
        (type == "directory" &&
         (baseName == "build" ||
          baseName == ".cache" ||
          baseName == ".direnv" ||
          baseName == ".github" ||
          baseName == ".pytest_cache" ||
          baseName == "__pycache__")));
    src = ./.;
  };

  postPatch = ''
    patchShebangs ./configure.py
    patchShebangs ./merge-compdb.py
    patchShebangs ./seastar/scripts/seastar-json2code.py
    patchShebangs ./seastar/cooking.sh
    patchShebangs ./install.sh
    substituteInPlace ./seastar/cooking.sh --replace flock ${util-linux}/bin/flock
  '';

  IMPLICIT_CFLAGS = ''
    ${readFile (llvmBundle.stdenv.cc + "/nix-support/libcxx-cxxflags")} ${readFile (llvmBundle.stdenv.cc + "/nix-support/libc-cflags")}
  '';

  configurePhase = ''
    ./configure.py ${if verbose then "--verbose " else ""}--mode=${mode}
  '';

  buildPhase = ''
    ${ninja}/bin/ninja build/${mode}/scylla
  '';

  installPhase = ''
    mkdir -p $out/bin
    mkdir -p $out/share
    cp build/release/scylla $out/bin
    cp -rv dist/common/* $out/share
  '';
}
