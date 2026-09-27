export type ProductDestination = 'library' | 'reader' | 'settings';

export class ProductShellState {
  private current: ProductDestination = 'library';

  destination(): ProductDestination {
    return this.current;
  }

  navigate(destination: ProductDestination): void {
    this.current = destination;
  }

  handleBack(): ProductDestination | undefined {
    if (this.current === 'settings' || this.current === 'reader') {
      this.current = 'library';
      return this.current;
    }
    return undefined;
  }
}
