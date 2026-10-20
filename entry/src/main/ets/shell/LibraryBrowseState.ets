import { LibrarySort } from '../services/LibraryQueryService';
import { LibraryFolder, BookOrganization } from '../domain/LibraryOrganization';

export interface LibraryBrowseContext {
  folderId: string;
  query: string;
  sort: LibrarySort;
  gridOffsetY: number;
  // Transient native viewport anchor; not a catalogue field or persisted locator.
  gridSourceTopVp?: number;
  // Recent-order viewport snapshot for a reading roundtrip; never persisted.
  readerReturnBookOrder?: string[];
  listOffsetY: number;
  sourceItemId: string;
}
export interface LibraryBrowseState extends LibraryBrowseContext {
  parents: LibraryBrowseContext[];
  folders: LibraryFolder[];
  memberships: BookOrganization[];
  organizationKnown: boolean;
}
export function createLibraryBrowseState(): LibraryBrowseState {
  return { folderId: '', query: '', sort: 'recent', gridOffsetY: 0, listOffsetY: 0,
    sourceItemId: '', parents: [], folders: [], memberships: [], organizationKnown: false };
}
export function copyLibraryBrowseContext(value: LibraryBrowseContext): LibraryBrowseContext {
  return { folderId: value.folderId, query: value.query, sort: value.sort,
    gridOffsetY: value.gridOffsetY, gridSourceTopVp: value.gridSourceTopVp,
    readerReturnBookOrder: value.readerReturnBookOrder?.slice(),
    listOffsetY: value.listOffsetY, sourceItemId: value.sourceItemId };
}
export function copyLibraryBrowseState(value: LibraryBrowseState): LibraryBrowseState {
  return { folderId: value.folderId, query: value.query, sort: value.sort,
    gridOffsetY: value.gridOffsetY, gridSourceTopVp: value.gridSourceTopVp, readerReturnBookOrder: value.readerReturnBookOrder?.slice(), listOffsetY: value.listOffsetY, sourceItemId: value.sourceItemId,
    parents: value.parents.map((parent: LibraryBrowseContext): LibraryBrowseContext => copyLibraryBrowseContext(parent)),
    folders: value.folders.slice(), memberships: value.memberships.slice(), organizationKnown: value.organizationKnown };
}
export function enterLibraryFolder(value: LibraryBrowseState, folderId: string, sourceItemId: string): LibraryBrowseState {
  const result = copyLibraryBrowseState(value);
  const parent = copyLibraryBrowseContext(value); parent.sourceItemId = sourceItemId;
  result.parents = [...result.parents, parent].slice(-32);
  result.folderId = folderId; result.gridOffsetY = 0; result.gridSourceTopVp = undefined; result.readerReturnBookOrder = undefined; result.listOffsetY = 0; result.sourceItemId = '';
  return result;
}
export function returnLibraryParent(value: LibraryBrowseState, parentId: string): LibraryBrowseState {
  const result = copyLibraryBrowseState(value);
  const parent = result.parents.pop();
  result.folderId = parentId; result.gridOffsetY = 0; result.gridSourceTopVp = undefined; result.readerReturnBookOrder = undefined; result.listOffsetY = 0; result.sourceItemId = '';
  if (parent?.folderId === parentId) {
    result.query = parent.query; result.sort = parent.sort;
    result.gridOffsetY = parent.gridOffsetY; result.listOffsetY = parent.listOffsetY; result.sourceItemId = parent.sourceItemId;
    result.gridSourceTopVp = parent.gridSourceTopVp;
    result.readerReturnBookOrder = parent.readerReturnBookOrder?.slice();
  } else result.parents = [];
  return result;
}

export function reconcileLibraryFolder(value: LibraryBrowseState, folders: LibraryFolder[]): LibraryBrowseState {
  if (!value.folderId || folders.some((folder: LibraryFolder): boolean => folder.folderId === value.folderId)) return value;
  let ancestor = value.folderId;
  let depth = 0;
  while (ancestor && depth++ < 32) {
    ancestor = value.folders.find((folder: LibraryFolder): boolean => folder.folderId === ancestor)?.parentId ?? '';
    if (!ancestor || folders.some((folder: LibraryFolder): boolean => folder.folderId === ancestor)) break;
  }
  const result = copyLibraryBrowseState(value);
  const index = result.parents.findIndex((context: LibraryBrowseContext): boolean => context.folderId === ancestor);
  if (index >= 0) {
    result.parents = result.parents.slice(0, index + 1);
    return returnLibraryParent(result, ancestor);
  }
  result.folderId = ancestor; result.parents = [];
  result.gridOffsetY = 0; result.gridSourceTopVp = undefined; result.readerReturnBookOrder = undefined;
  result.listOffsetY = 0; result.sourceItemId = '';
  return result;
}
