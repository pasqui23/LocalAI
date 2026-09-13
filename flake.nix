# Made by Azteczek
{
  description = "LocalAI flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };

      reactUi = pkgs.buildNpmPackage {
        pname = "localai-react-ui";
        version = "custom";
        src = ./core/http/react-ui;
        npmDeps = pkgs.importNpmLock {
          npmRoot = ./core/http/react-ui;
        };
        npmConfigHook = pkgs.importNpmLock.npmConfigHook;
        npmBuildScript = "build";

        installPhase = ''
          runHook preInstall
          mkdir -p $out
          cp -r dist $out/
          runHook postInstall
        '';
      };

      # Build localai with optional acceleration
      mkLocalaiPackage = { name, acceleration ? "none" }:
        pkgs.buildGoModule {
          pname = name;
          version = "custom";

          src = ./.;
          proxyVendor = true;
          vendorHash = "sha256-QWcuXFbzqqFUIgXDejQngUsTKNO0eimvMskqLSjte+g=";

          nativeBuildInputs = with pkgs;  [
            pkg-config cmake gcc protobuf go-protobuf protoc-gen-go protoc-gen-go-grpc
          ] ++
            (if acceleration == "vulkan" then [
            vulkan-headers vulkan-loader shaderc spirv-headers
          ]
            else if acceleration == "cuda" then [
            cudatoolkit
          ]
            else []);

          env = {
            BUILD_TYPE = acceleration;
            CGO_ENABLED = if acceleration == "none" then "0" else "1";
          };

          preBuild = ''
            ${
              if acceleration == "vulkan" then
                ''
                  export LD_LIBRARY_PATH=${pkgs.vulkan-loader}/lib:$LD_LIBRARY_PATH
                  export VULKAN_HEADERS=${pkgs.vulkan-headers}/include
                ''
              else if acceleration == "cublas" then
                ''
                  export LD_LIBRARY_PATH=${pkgs.cudatoolkit}/lib:$LD_LIBRARY_PATH
                ''
              else ""
            }

            PROTO_SOURCE_DIR=$(find . -name "*.proto" -printf "%h" -quit)
            mkdir -p pkg/grpc/proto
            ${pkgs.protobuf}/bin/protoc \
              -I=$PROTO_SOURCE_DIR \
              -I. \
              --go_out=pkg/grpc/proto --go_opt=paths=source_relative \
              --go-grpc_out=pkg/grpc/proto --go-grpc_opt=paths=source_relative \
              $PROTO_SOURCE_DIR/*.proto

            go mod edit -replace github.com/mudler/LocalAI/pkg/grpc/proto=./pkg/grpc/proto

            mkdir -p core/http/react-ui
            cp -r ${reactUi}/dist core/http/react-ui/dist

            sed -i '/go:generate/d' core/config/inference_defaults.go || true
          '';

          subPackages = [ "cmd/local-ai" ];
          doCheck = false;

          postInstall = ''
            [ -f $out/bin/local-ai ] && mv $out/bin/local-ai $out/bin/localai
          '';
        };
        mkLocalaiWrapped = {name, acceleration ? "none"}:
          let localai-unwrapped = mkLocalaiPackage { name = "${name}-unwrapped"; inherit acceleration; }; in
          pkgs.buildFHSEnv {
          name = "localai";
          targetPkgs = pkgs: with pkgs; [
            localai-unwrapped
            bash
            coreutils
            gnugrep
          ];
          runScript = "${localai-unwrapped}/bin/localai";
        };
    in {
      packages.${system} = {
        localai-unwrapped = mkLocalaiPackage { name = "localai"; };

        default = mkLocalaiWrapped { name = "localai"; acceleration = "none"; };
        vulkan = mkLocalaiWrapped { name = "localai-vulkan"; acceleration = "vulkan"; };
        cuda = mkLocalaiWrapped { name = "localai-cuda"; acceleration = "cublas"; };
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          go
          gnumake
          pkg-config
          cmake
          ccache
          protobuf
          go-protobuf
          protoc-gen-go
          protoc-gen-go-grpc
          grpc
          vulkan-headers
          vulkan-loader
          vulkan-tools
          shaderc
          spirv-headers
          nodejs
          bun
          chromium
          golangci-lint
          gofumpt
          gotools
          go-tools
          ffmpeg-headless
          git
          curl
        ];

        shellHook = ''
          export PLAYWRIGHT_CHROMIUM_PATH="${pkgs.chromium}/bin/chromium"
          export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

          echo "LocalAI dev shell: $(go version), node $(node --version)"
          echo "Build:       make build       (Go binary + React UI)"
          echo "React UI:    make react-ui    (npm install && vite build)"
          echo "Lint:        make lint        (only new issues vs master)"
          echo "           or make lint-all   (full baseline)"
        '';
      };
    };
}
