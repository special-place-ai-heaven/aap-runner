/* Compiles, then fails to link: missing_function has no definition. */
int missing_function(void);
int main(void) { return missing_function(); }
