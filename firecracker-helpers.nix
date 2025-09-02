# firecracker-helpers.nix
{ lib
, stdenv
, fetchFromGitHub
, makeWrapper
, wrapperDir ? "/run/wrappers/bin" # NixOS security wrappers location
, curl
, iproute2
, wget
, docker
, e2fsprogs
, openssh
, systemd
, coreutils
, findutils
, gawk
, gnugrep
, gnused
, util-linux
, libcap
}:

# Configuration - modify these paths as needed
let
  # GitHub repository configuration
  owner = "nulvox";  # Change this to your GitHub username
  repo = "firecracker-helpers";      # Change this to your repository name
  rev = "main";                    # Change this to specific commit/tag if desired
  
  # Installation paths for each script - customize as needed
  installPaths = {
    fc-kernel = "bin/fc-kernel.sh";
    fc-rootfs = "bin/fc-rootfs.sh";
    fc-nethelper = "bin/fc-nethelper";
    # Add more scripts here as: script-name = "relative/path/from/store";
  };
  
  # Source paths in your repository - update these to match your repo structure
  sourcePaths = {
    fc-kernel = "fc-kernel.sh";
    fc-rootfs = "fc-rootfs.sh";
    fc-nethelper = "fc-nethelper"; 
  };

in stdenv.mkDerivation rec {
  pname = "firecracker-helpers";
  version = "1.0.0";

  src = fetchFromGitHub {
    inherit owner repo rev;
    sha256 = "k1igjHTxSImLGGDlOXn5i03tYpzpeTwzeaUzr2XJkTs=";
  };

  nativeBuildInputs = [ makeWrapper ];

  # Runtime dependencies
  buildInputs = [
    curl
    wget
    docker
    e2fsprogs
    openssh
    systemd
    coreutils
    findutils
    gawk
    gnugrep
    gnused
    util-linux
    libcap
  ];

  # Don't run configure/make
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (scriptName: installPath: 
      let sourcePath = sourcePaths.${scriptName} or "${scriptName}.sh";
      in ''
        # Install ${scriptName}
        if [ -f "${sourcePath}" ]; then
          ${if scriptName == "fc-nethelper" then ''
            # Special handling for fc-nethelper - needs capabilities
            install -m 755 "${sourcePath}" "$out/${installPath}"
            
            # Set capabilities on the binary (will be lost, but documented)
            echo "fc-nethelper installed - requires CAP_NET_ADMIN capability"
            echo "Run: sudo setcap cap_net_admin+ep $out/${installPath}"
            echo "Or use NixOS security wrapper (see passthru.securityWrapper)"
            
            # Don't wrap fc-nethelper with other dependencies to avoid capability issues
          '' else ''
            install -m 755 "${sourcePath}" "$out/${installPath}"
            
            # Wrap the script with runtime dependencies in PATH
            wrapProgram "$out/${installPath}" \
              --prefix PATH : ${lib.makeBinPath [
                curl
                wget
                docker
                e2fsprogs
                openssh
                systemd
                coreutils
                findutils
                gawk
                gnugrep
                gnused
                util-linux
                libcap
              ]}
          ''}
        else
          echo "Warning: Source file ${sourcePath} not found for ${scriptName}"
        fi
      ''
    ) installPaths)}

    runHook postInstall
  '';

  # Add shell completions if your scripts support them
  postInstall = ''
    # Create symlinks with more convenient names if desired
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (scriptName: installPath: ''
      # Optional: create additional symlinks
      # ln -s "$out/${installPath}" "$out/bin/${scriptName}"
    '') installPaths)}
  '';

  # Provide security wrapper configuration for NixOS
  passthru.securityWrapper = {
    fc-nethelper = {
      source = "${placeholder "out"}/bin/fc-nethelper";
      owner = "root";
      group = "root";
      capabilities = "cap_net_admin+ep";
      permissions = "u+rx,g+x,o+x";
    };
  };

  meta = with lib; {
    description = "Tools for working with Firecracker microVMs - kernel and rootfs builders";
    longDescription = ''
      A collection of scripts for building and managing Firecracker microVM components:
      - fc-kernel.sh: Download CI-built kernels and configurations
      - fc-rootfs.sh: Build rootfs images from Docker images/Dockerfiles
      - fc-nethelper: Network helper for Firecracker (requires CAP_NET_ADMIN)
      
      These tools simplify the process of creating Firecracker-compatible kernels
      and root filesystems for microVM development and testing.
      
      For fc-nethelper, either use sudo setcap or configure NixOS security wrapper:
        security.wrappers.fc-nethelper = pkgs.firecracker-helpers.passthru.securityWrapper.fc-nethelper;
    '';
    homepage = "https://github.com/${owner}/${repo}";
    license = licenses.mit;  # Change to match your license
    maintainers = [ ];  # Add your maintainer info if desired
    platforms = platforms.linux;  # These tools are Linux-specific
  };
}