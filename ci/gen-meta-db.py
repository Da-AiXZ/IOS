#!/usr/bin/env python3
"""Generate meta.db from an extracted Alpine rootfs directory.
Replaces fakefsify (which requires native C compilation).
Usage: python3 ci/gen-meta-db.py <rootfs_data_dir> <output_meta_db>
Example: python3 ci/gen-meta-db.py Payload/AgentBox.app/rootfs/data Payload/AgentBox.app/rootfs/meta.db
"""
import sqlite3
import os
import struct
import sys

# ish_stat struct format (from fs/fake.h):
#   dword_t mode;   // 4 bytes
#   dword_t uid;    // 4 bytes
#   dword_t gid;    // 4 bytes
#   dword_t rdev;   // 4 bytes
# Total: 16 bytes, little-endian
def pack_ish_stat(mode, uid=0, gid=0, rdev=0):
    return struct.pack('<IIII', mode, uid, gid, rdev)

# Platform-independent S_IFMT constants (match POSIX + Linux + macOS)
S_IFMT  = 0o170000
S_IFDIR = 0o040000
S_IFREG = 0o100000
S_IFLNK = 0o120000
S_IFCHR = 0o020000
S_IFBLK = 0o060000
S_IFIFO = 0o010000
S_IFSOCK = 0o140000

def entry_type(st_mode):
    """Map os.lstat st_mode to ish S_IFMT + permissions."""
    if os.path.isfile:  # S_ISREG
        pass
    m = st_mode & 0o777  # permissions
    if st_mode & 0o40000:  # S_IFDIR (0x4000)
        return S_IFDIR | m
    elif st_mode & 0o100000:  # S_IFREG (0x8000)
        return S_IFREG | m
    elif st_mode & 0o120000:  # S_IFLNK (0xA000)
        return S_IFLNK | 0o777
    elif st_mode & 0o2000:  # S_IFCHR (0x2000)
        return S_IFCHR | m
    elif st_mode & 0o6000:  # S_IFBLK (0x6000)
        return S_IFBLK | m
    else:
        return S_IFREG | m  # fallback

def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <rootfs_data_dir> <output_meta_db>")
        sys.exit(1)

    data_dir = sys.argv[1]
    meta_path = sys.argv[2]

    if not os.path.isdir(data_dir):
        print(f"ERROR: data_dir not found: {data_dir}")
        sys.exit(1)

    # Remove stale meta.db if it exists
    if os.path.exists(meta_path):
        os.remove(meta_path)

    db = sqlite3.connect(meta_path)
    db.execute('PRAGMA journal_mode=WAL')

    # Schema (matches fs/fake-migrate.c version 0 + version 1)
    db.execute('CREATE TABLE stats (inode integer primary key, stat blob)')
    db.execute('CREATE TABLE paths (path blob primary key, inode integer references stats(inode))')
    db.execute('CREATE INDEX inode_to_path ON paths (inode, path)')
    db.execute('CREATE TABLE meta (db_inode integer)')
    db.execute('INSERT INTO meta (db_inode) VALUES (0)')

    # Insert root entry ("")
    root_blob = pack_ish_stat(S_IFDIR | 0o755)
    db.execute('INSERT INTO stats (stat) VALUES (?)', (root_blob,))
    root_inode = db.execute('SELECT last_insert_rowid()').fetchone()[0]
    db.execute('INSERT INTO paths (path, inode) VALUES (?, ?)', (b'', root_inode))

    # Walk directory tree
    entries = []
    for dirpath, dirnames, filenames in os.walk(data_dir):
        rel_dir = os.path.relpath(dirpath, data_dir)
        if rel_dir == '.':
            rel_dir = ''

        for name in sorted(dirnames):
            full = os.path.join(dirpath, name)
            st = os.lstat(full)
            rel = os.path.join(rel_dir, name) if rel_dir else name
            # os.walk traverses dirs, interpret as directory
            mode = S_IFDIR | (st.st_mode & 0o777)
            entries.append((rel, mode, 0, 0, 0))

        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            st = os.lstat(full)
            rel = os.path.join(rel_dir, name) if rel_dir else name
            mode = entry_type(st.st_mode)
            entries.append((rel, mode, 0, 0, 0))

    # Insert all entries
    for path, mode, uid, gid, rdev in entries:
        blob = pack_ish_stat(mode, uid, gid, rdev)
        cursor = db.execute('INSERT INTO stats (stat) VALUES (?)', (blob,))
        inode = cursor.lastrowid
        # Use binary path (Alpine paths are ASCII-compatible)
        db.execute('INSERT INTO paths (path, inode) VALUES (?, ?)',
                   (path.encode('utf-8'), inode))

    # Set user_version to match latest migration (version 3 from fake-migrate.c)
    db.execute('PRAGMA user_version = 3')

    db.commit()
    db.close()

    # Verify
    size = os.path.getsize(meta_path)
    print(f"meta.db created: {size} bytes, {len(entries)} entries")

if __name__ == '__main__':
    main()
