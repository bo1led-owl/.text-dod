for name in aos soa aos-compact
    for file in zig-out/inputs/*
        set basename (basename $file)
        zig build --release=fast run-$name-preprocessor < $file > preprocessed/$basename-$name
    end
end
