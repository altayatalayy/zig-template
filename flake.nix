{
  description = "Jinja-subset template engine for Zig code generation";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig.url = "github:mitchellh/zig-overlay";
    zig.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, zig }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forEachSystem = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forEachSystem (system: {
        default = nixpkgs.legacyPackages.${system}.mkShell {
          packages = [ zig.packages.${system}."0.17.1" ];
        };
      });

      checks = forEachSystem (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          zigCompiler = zig.packages.${system}."0.17.1";

          check = name: script: pkgs.runCommand name
            {
              src = self;
              nativeBuildInputs = [ zigCompiler ];
            }
            ''
              cp --recursive "$src" source
              chmod --recursive u+w source
              cd source
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
              export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
              ${script}
              touch "$out"
            '';
        in
        {
          format = check "zig-fmt" "zig fmt --check build.zig src examples";
          test = check "zig-test" "zig build test --summary all";
        });
    };
}
