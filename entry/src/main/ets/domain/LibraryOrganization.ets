export const ROOT_FOLDER: string = '';
export interface LibraryFolder { folderId: string; parentId: string; name: string; }
export interface BookOrganization {
  bookId: string;
  folderId: string;
  seriesName: string;
  volumeOrder?: number;
}
export interface SeriesContinuation {
  status: 'next' | 'choose' | 'end' | 'unordered';
  bookIds: string[];
  // M6 opens the selected book at its saved logical source page, or page zero.
  position: 'saved-logical-page-or-zero';
}
export function seriesContinuation(current: BookOrganization,
  members: BookOrganization[]): SeriesContinuation {
  const result: SeriesContinuation = { status: 'unordered', bookIds: [], position: 'saved-logical-page-or-zero' };
  if (!current.seriesName || current.volumeOrder === undefined) return result;
  const later = members.filter((item: BookOrganization): boolean =>
    item.seriesName === current.seriesName && item.volumeOrder !== undefined && item.volumeOrder > current.volumeOrder!);
  if (later.length === 0) { result.status = 'end'; return result; }
  const nextOrder = Math.min(...later.map((item: BookOrganization): number => item.volumeOrder!));
  result.bookIds = later.filter((item: BookOrganization): boolean => item.volumeOrder === nextOrder)
    .map((item: BookOrganization): string => item.bookId);
  result.status = result.bookIds.length === 1 ? 'next' : 'choose';
  return result;
}

// Removal includes descendant directories; submit each selected tree once.
export function topLevelSelectedFolders(folders: LibraryFolder[], selected: string[]): LibraryFolder[] {
  return folders.filter((folder: LibraryFolder): boolean => {
    if (!folder.folderId || !selected.includes(folder.folderId)) return false;
    let parent = folder.parentId;
    const visited: string[] = [folder.folderId];
    while (parent) {
      if (selected.includes(parent) || visited.includes(parent)) return false;
      visited.push(parent);
      parent = folders.find((item: LibraryFolder): boolean => item.folderId === parent)?.parentId ?? '';
    }
    return true;
  });
}

export interface LibraryDeletionScope {
  roots: LibraryFolder[];
  folders: LibraryFolder[];
  bookIds: string[];
}
export function folderSubtree(folders: LibraryFolder[], root: string): LibraryFolder[] {
  const ids: string[] = [root];
  for (let index = 0; index < ids.length; index++) {
    for (const folder of folders) if (folder.parentId === ids[index] && !ids.includes(folder.folderId)) ids.push(folder.folderId);
  }
  return folders.filter((folder: LibraryFolder): boolean => ids.includes(folder.folderId));
}
export function libraryDeletionScope(folders: LibraryFolder[], memberships: BookOrganization[],
  selectedFolders: string[], selectedBooks: string[]): LibraryDeletionScope {
  if (selectedFolders.some((id: string): boolean => !id || !folders.some((folder: LibraryFolder): boolean => folder.folderId === id)))
    throw new Error('Folder unavailable');
  const roots = topLevelSelectedFolders(folders, selectedFolders);
  const descendants: LibraryFolder[] = [];
  for (const root of roots) for (const folder of folderSubtree(folders, root.folderId)) {
    if (!descendants.some((item: LibraryFolder): boolean => item.folderId === folder.folderId)) descendants.push(folder);
  }
  const ids = selectedBooks.filter((id: string, index: number): boolean => id.length > 0 && selectedBooks.indexOf(id) === index);
  for (const member of memberships) if (descendants.some((folder: LibraryFolder): boolean => folder.folderId === member.folderId) && !ids.includes(member.bookId)) ids.push(member.bookId);
  return { roots, folders: descendants, bookIds: ids };
}
