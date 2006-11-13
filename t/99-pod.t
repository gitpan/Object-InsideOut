use strict;
use warnings;

use Test::More 'no_plan';

SKIP: {
    eval 'use Test::Pod 1.26';
    skip('Test::Pod 1.26 required for testing POD', 1) if $@;

    pod_file_ok('blib/lib/Object/InsideOut.pm');
    pod_file_ok('blib/lib/Object/InsideOut/Metadata.pm');
    pod_file_ok('blib/lib/Bundle/Object/InsideOut.pm');
}

SKIP: {
    eval 'use Test::Pod::Coverage 1.08';
    skip('Test::Pod::Coverage 1.08 required for testing POD coverage', 1) if $@;

    pod_coverage_ok('Object::InsideOut',
                    {
                        'trustme' => [
                            qr/^new$/,
                            qr/^clone$/,
                            qr/^set$/,
                            qr/^meta$/,
                            qr/^create_field$/,
                            qr/^add_class$/,
                        ],
                        'private' => [
                            qr/^STORABLE_freeze$/,
                            qr/^STORABLE_thaw$/,
                            qr/^create_CHAINED$/,
                            qr/^create_CUMULATIVE$/,
                            qr/^create_HIDDEN$/,
                            qr/^create_PRIVATE$/,
                            qr/^create_RESTRICTED$/,
                            qr/^create_ARG_WRAP$/,
                            qr/^create_accessors$/,
                            qr/^create_heritage$/,
                            qr/^create_lvalue_accessor$/,
                            qr/^export_methods$/,
                            qr/^generate_CHAINED$/,
                            qr/^generate_CUMULATIVE$/,
                            qr/^generate_OVERLOAD$/,
                            qr/^initialize$/,
                            qr/^install_ATTRIBUTES$/,
                            qr/^install_UNIVERSAL$/,
                            qr/^is_sharing$/,
                            qr/^load$/,
                            qr/^preamble_code$/,
                            qr/^type_code$/,
                            qr/^process_fields$/,
                            qr/^set_sharing$/,
                            qr/^sub_name$/,
                            qr/^AUTOLOAD$/,
                            qr/^CLONE$/,
                            qr/^DESTROY$/,
                            qr/^MODIFY_ARRAY_ATTRIBUTES$/,
                            qr/^MODIFY_CODE_ATTRIBUTES$/,
                            qr/^MODIFY_HASH_ATTRIBUTES$/,
                            qr/^_ID$/,
                            qr/^_args$/,
                            qr/^_obj$/,
                            qr/^import$/,
                        ]
                    }
    );

    pod_coverage_ok('Object::InsideOut::Metadata', {
                        'trustme' => [ qr/^add_meta$/ ],
                    }
    );
}

# EOF
