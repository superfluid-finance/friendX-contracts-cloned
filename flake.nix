{
  description = "A good flake for good frens";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    foundry = {
      url = "github:shazow/foundry.nix/monthly";
      inputs.flake-utils.follows = "flake-utils";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    solc = {
      url = "github:hellwolf/solc.nix";
      inputs.flake-utils.follows = "flake-utils";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, flake-utils, nixpkgs, foundry, solc }:
  flake-utils.lib.eachDefaultSystem (system:
  let
    solcVer = "solc_0_8_23";
    pkgs = import nixpkgs {
      inherit system;
      overlays = [
        foundry.overlay
        solc.overlay
      ];
    };
  in {
    # local development shells
    devShells.default = with pkgs; mkShell {
      buildInputs = [
        nodePackages_latest.pnpm
        jq
        yq
        foundry-bin
        # slither-analyzer
        # echidna
        pkgs.${solcVer}
        (solc.mkDefault pkgs pkgs.${solcVer})
      ];
    };
  });
}
