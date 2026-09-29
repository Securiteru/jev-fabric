/** This package's version; the platform packages are pinned to the same version. */
export declare const version: string;
/** The per-platform package for a host, or undefined where none is published. */
export declare function platformPackage(platform?: string, arch?: string): string | undefined;
/** Absolute path of the installed native executable, or undefined. */
export declare function binaryPath(): string | undefined;
/** Directory holding python/jev_fabric.py and typescript/jev-fabric.ts. */
export declare const clientsDirectory: string;
