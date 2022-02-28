typedef void (*read_ballot_cb)(unsigned char *, unsigned char *, int, void *);
typedef void (*read_ballots_cb)(const char *);

extern void read_ballot(unsigned char *output, const char *filepath, const char numNodes,
                        const char numChunks, read_ballot_cb f, void *f_data);

extern void read_ballots(const char *folder, const char *prefix, read_ballots_cb f);