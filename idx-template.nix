{pkgs, example ? "app", ...}: {
    packages = [
        pkgs.curl
        pkgs.gnutar
        pkgs.xz
        pkgs.git
        pkgs.busybox
    ];
    bootstrap = ''
        mkdir "$out"
        cp -rf ${./.}/examples/${example}/* "$out"
        mkdir "$out"/.idx
        cp ${./dev.nix} "$out"/.idx/dev.nix
        chmod -R u+w "$out"
        install --mode u+rw ${./dev.nix} "$out"/.idx/dev.nix
    '';
}