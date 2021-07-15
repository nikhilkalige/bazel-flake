{ pkgs, src, version }:

with pkgs;
let
  sourceRoot = ".";
  system = if stdenv.hostPlatform.isDarwin then "darwin" else "linux";
  arch = stdenv.hostPlatform.parsed.cpu.name;
  javaToolchain = "@bazel_tools//tools/jdk:toolchain";
  jdk = openjdk11_headless;
  defaultShellPath = lib.makeBinPath [ bash coreutils findutils gawk gnugrep gnutar gnused gzip which unzip file zip python27 python3 ];
  customBash = writeCBin "bash" ''
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <unistd.h>

    extern char **environ;

    int main(int argc, char *argv[]) {
      char *path = getenv("PATH");
      char *pathToAppend = "${defaultShellPath}";
      char *newPath;
      if (path != NULL) {
        int length = strlen(path) + 1 + strlen(pathToAppend) + 1;
        newPath = malloc(length * sizeof(char));
        snprintf(newPath, length, "%s:%s", path, pathToAppend);
      } else {
        newPath = pathToAppend;
      }
      setenv("PATH", newPath, 1);
      execve("${bash}/bin/bash", argv, environ);
      return 0;
    }
  '';
  srcDeps = lib.attrsets.attrValues srcDepsSet;
  srcDepsSet =
    let
      srcs = (builtins.fromJSON (builtins.readFile ./src-deps.json));
      toFetchurl = d: lib.attrsets.nameValuePair d.name (fetchurl {
        urls = d.urls;
        sha256 = d.sha256;
      });
    in
    builtins.listToAttrs (map toFetchurl [
      srcs.desugar_jdk_libs
      srcs.io_bazel_skydoc
      srcs.bazel_skylib
      srcs.io_bazel_rules_sass
      srcs.platforms
      srcs."coverage_output_generator-v2.5.zip"
      srcs.build_bazel_rules_nodejs
      srcs."android_tools_pkg-0.23.0.tar.gz"
      srcs.bazel_toolchains
      srcs.com_github_grpc_grpc
      srcs.upb
      srcs.com_google_protobuf
      srcs.rules_pkg
      srcs.rules_cc
      srcs.rules_java
      srcs.rules_proto
      srcs.com_google_absl
      srcs.com_github_google_re2
      srcs.com_github_cares_cares
      srcs."java_tools-v11.3.zip"

      srcs."remote_java_tools_${system}_for_testing"
      srcs."remotejdk11_${system}"
    ]);

  distDir = runCommand "bazel-deps" { } ''
    mkdir -p $out
    for i in ${builtins.toString srcDeps}; do cp $i $out/$(stripHash $i); done
  '';
  remote_java_tools = stdenv.mkDerivation {
    inherit sourceRoot;

    name = "remote_java_tools_${system}";

    src = srcDepsSet."remote_java_tools_${system}_for_testing";

    nativeBuildInputs = [ autoPatchelfHook unzip ];
    buildInputs = [ gcc-unwrapped ];


    buildPhase = ''
      mkdir $out;
    '';

    installPhase = ''
      cp -Ra * $out/
      touch $out/WORKSPACE
    '';
  };
  bazelRC = writeTextFile {
    name = "bazel-rc";
    text = ''
      startup --server_javabase=${jdk}

      build --distdir=${distDir}
      fetch --distdir=${distDir}
      query --distdir=${distDir}

      build --override_repository=${remote_java_tools.name}=${remote_java_tools}
      fetch --override_repository=${remote_java_tools.name}=${remote_java_tools}
      query --override_repository=${remote_java_tools.name}=${remote_java_tools}

      # Provide a default java toolchain, this will be the same as ${jdk}
      build --host_javabase='@local_jdk//:jdk'
      build --incompatible_use_toolchain_resolution_for_java_rules

      # load default location for the system wide configuration
      try-import /etc/bazel.bazelrc
    '';
  };
in
buildBazelPackage {
  inherit src version;
  pname = "bazel";

  buildInputs = [ python3 jdk ];

  bazel = bazel_4;
  bazelTarget = "//src:bazel";
  bazelFetchFlags = [
    "--loading_phase_threads=HOST_CPUS"
  ];
  bazelFlags = [
    "-c opt"
    "--define=ABSOLUTE_JAVABASE=${jdk.home}"
    "--host_javabase=@bazel_tools//tools/jdk:absolute_javabase"
    "--javabase=@bazel_tools//tools/jdk:absolute_javabase"
  ];
  fetchConfigured = true;

  dontAddBazelOpts = true;

  fetchAttrs.sha256 = "SavpxxfBvn+k9OPc8O+eT5EwMS02uhKov2zC9MuaebA=";

  buildAttrs = {
    patches = [
      (substituteAll {
        src = ./patches/strict_action_env.patch;
        strictActionEnvPatch = defaultShellPath;
      })
      (substituteAll {
        src = ./patches/bazel_rc.patch;
        bazelSystemBazelRCPath = bazelRC;
      })
    ];

    postPatch = ''
      # Substitute j2objc and objc wrapper's python shebang to plain python path.
      # These scripts explicitly depend on Python 2.7, hence we use python27.
      # See also `postFixup` where python27 is added to $out/nix-support
      substituteInPlace tools/j2objc/j2objc_header_map.py --replace "$!/usr/bin/python2.7" "#!${python27}/bin/python"
      substituteInPlace tools/j2objc/j2objc_wrapper.py --replace "$!/usr/bin/python2.7" "#!${python27}/bin/python"
      substituteInPlace tools/objc/j2objc_dead_code_pruner.py --replace "$!/usr/bin/python2.7" "#!${python27}/bin/python"

      # md5sum is part of coreutils
      sed -i 's|/sbin/md5|md5sum|' src/BUILD

      # replace initial value of pythonShebang variable in BazelPythonSemantics.java
      substituteInPlace src/main/java/com/google/devtools/build/lib/bazel/rules/python/BazelPythonSemantics.java \
        --replace '"#!/usr/bin/env " + pythonExecutableName' "\"#!${python3}/bin/python\""

      # substituteInPlace is rather slow, so prefilter the files with grep
      grep -rlZ /bin src/main/java/com/google/devtools | while IFS="" read -r -d "" path; do
        # If you add more replacements here, you must change the grep above!
        # Only files containing /bin are taken into account.
        # We default to python3 where possible. See also `postFixup` where
        # python3 is added to $out/nix-support
        substituteInPlace "$path" \
          --replace /bin/bash ${customBash}/bin/bash \
          --replace "/usr/bin/env bash" ${customBash}/bin/bash \
          --replace "/usr/bin/env python" ${python3}/bin/python \
          --replace /usr/bin/env ${coreutils}/bin/env \
          --replace /bin/true ${coreutils}/bin/true
      done

      # bazel test runner include references to /bin/bash
      substituteInPlace tools/build_rules/test_rules.bzl --replace /bin/bash ${customBash}/bin/bash

      for i in $(find tools/cpp/ -type f)
      do
        substituteInPlace $i --replace /bin/bash ${customBash}/bin/bash
      done

      # Fixup scripts that generate scripts. Not fixed up by patchShebangs below.
      substituteInPlace scripts/bootstrap/compile.sh --replace /bin/bash ${customBash}/bin/bash

      # append the PATH with defaultShellPath in tools/bash/runfiles/runfiles.bash
      echo "PATH=\$PATH:${defaultShellPath}" >> runfiles.bash.tmp
      cat tools/bash/runfiles/runfiles.bash >> runfiles.bash.tmp
      mv runfiles.bash.tmp tools/bash/runfiles/runfiles.bash

      patchShebangs .
    '';

    installPhase = ''
      mkdir -p $out/bin
      mv bazel-bin/src/bazel $out/bin/bazel
    '';

    # doInstallCheck = true;
    # installCheckPhase = ''
    #   export TEST_TMPDIR=$(pwd)

    #   hello_test () {
    #     $out/bin/bazel test \
    #       --test_output=errors \
    #       examples/cpp:hello-success_test \
    #       examples/java-native/src/test/java/com/example/myproject:hello
    #   }

    #   # test whether $WORKSPACE_ROOT/tools/bazel works

    #   mkdir -p tools
    #   cat > tools/bazel <<"EOF"
    #   #!${runtimeShell} -e
    #   exit 1
    #   EOF
    #   chmod +x tools/bazel

    #   # first call should fail if tools/bazel is used
    #   ! hello_test

    #   cat > tools/bazel <<"EOF"
    #   #!${runtimeShell} -e
    #   exec "$BAZEL_REAL" "$@"
    #   EOF

    #   # second call succeeds because it defers to $out/bin/bazel-{version}-{os_arch}
    #   hello_test
    # '';

    # Save paths to hardcoded dependencies so Nix can detect them.
    postFixup = ''
      mkdir -p $out/nix-support
      echo "${customBash} ${defaultShellPath}" >> $out/nix-support/depends
      # The templates get tar’d up into a .jar,
      # so nix can’t detect python is needed in the runtime closure
      # Some of the scripts explicitly depend on Python 2.7. Otherwise, we
      # default to using python3. Therefore, both python27 and python3 are
      # runtime dependencies.
      echo "${python27}" >> $out/nix-support/depends
      echo "${python3}" >> $out/nix-support/depends
    '' + lib.optionalString stdenv.isDarwin ''
      echo "${cctools}" >> $out/nix-support/depends
    '';

    dontStrip = true;
    dontPatchELF = true;
  };
}
