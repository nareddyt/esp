# Copyright (C) Endpoints Server Proxy Authors
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#
################################################################################
#
use strict;
use warnings;

#### HELLO, FUTURE MAINTAINER OF THIS CODE!
#### READ THIS IF THE TEST IS FAILING AND THE OTHER TESTS ARE ALL WORKING

# This test depends on a self-signed certificate.  It might fail if
# the certificate expires.  So you might need to periodically
# regenerate the certificate.  This is pretty easy -- just follow the
# instructions below for test.crt, or use whatever future technology
# is appropriate to the situation.


################################################################################

BEGIN { use FindBin; chdir($FindBin::Bin); }

use ApiManager;   # Must be first (sets up import path to the Nginx test module)
use Test::Nginx;  # Imports Nginx's test module
use Test::More;   # And the test framework
use HttpServer;

################################################################################

# Port assignments
my $GrpcNginxPort = 8080;
my $GrpcBackendPort = 8082;
my $ServiceControlPort = 8081;
my $HttpNginxPort = 8083;
my $HttpBackendPort = 8085;

my $t = Test::Nginx->new()->has(qw/http proxy/)->plan(4);

$t->write_file('service.pb.txt', ApiManager::get_grpc_test_service_config . <<"EOF");
control {
  environment: "http://127.0.0.1:${ServiceControlPort}"
}
system_parameters {
  rules {
    selector: "test.grpc.Test.Echo"
    parameters {
      name: "api_key"
      http_header: "x-api-key"
    }
  }
}
EOF

# For posterity, here's where the next three files came from:
#
# * roots.pem was originally copied from the GRPC sources.
#
# * test.key was generated by openssl:
#
#     $ openssl genrsa -out test.key 2048
#
# * test.crt is a self-signed certificate, which is useful for testing
#   but not much else.  To create it, we started by generating a
#   certificate signing request:
#
#     $ openssl req -new -key test.key -out test.csr
#
#   and used it to generate a self-signed certificate good for one year:
#
#     $ openssl x509 -req -days 365 -in test.csr -signkey test.key -out test.crt
#
#   (For an actual production site, you'd send the certificate signing
#   request to a certificate authority, and they'd send you the
#   certificate.  But we're not going to check an actual production
#   certificate into the Endpoints test code.)
#
#   When creating the certificate signing request, it's important to
#   specify "localhost" as the common name (server FQDN), since that's
#   what used to connect to the server in the test.

$t->write_file('roots.pem', ApiManager::read_test_file('testdata/roots.pem'));
$t->write_file('test.key', ApiManager::read_test_file('testdata/test.key'));
$t->write_file('test.crt', ApiManager::read_test_file('testdata/test.crt'));

ApiManager::write_file_expand($t, 'nginx.conf', <<"EOF");
%%TEST_GLOBALS%%
daemon off;
events {
  worker_connections 32;
}
http {
  %%TEST_GLOBALS_HTTP%%
  server {
    listen 127.0.0.1:${GrpcNginxPort} ssl http2;
    ssl_certificate_key test.key;
    ssl_certificate test.crt;
    server_name localhost;
    location / {
      endpoints {
        api service.pb.txt;
        %%TEST_CONFIG%%
        on;
      }
      grpc_pass {
        proxy_pass http://127.0.0.1:${HttpBackendPort};
      }
    }
  }
}
EOF

$t->run_daemon(\&service_control, $t, $ServiceControlPort, 'requests.log');
$t->run_daemon(\&ApiManager::grpc_test_server, $t, "127.0.0.1:${GrpcBackendPort}");
$t->run_daemon(\&ApiManager::not_found_server, $t, $HttpBackendPort);
is($t->waitforsocket("127.0.0.1:${ServiceControlPort}"), 1, 'Service control socket ready.');
is($t->waitforsocket("127.0.0.1:${GrpcBackendPort}"), 1, 'GRPC test server socket ready.');
$t->run();
is($t->waitforsocket("127.0.0.1:${GrpcNginxPort}"), 1, 'Nginx socket ready.');

################################################################################

# Note: libgrpc will use this environment variable to look up its root
# certificates file.  Pointing it at the server's certificate
# effectively tells libgrpc to trust the server's certificate, which
# is useful since it's not actually signed by a real certificate
# authority.
$ENV{'GRPC_DEFAULT_SSL_ROOTS_FILE_PATH'} = $t->testdir() . '/test.crt';

my $test_results = &ApiManager::run_grpc_test($t, <<"EOF");
server_addr: "localhost:${GrpcNginxPort}"
plans {
  echo {
    request {
      text: "Hello, world!"
    }
    call_config {
      api_key: "this-is-an-api-key"
      use_ssl: true
    }
  }
}
EOF

$t->stop_daemons();

my $test_results_expected = <<'EOF';
results {
  echo {
    text: "Hello, world!"
  }
}
EOF
is($test_results, $test_results_expected, 'Client tests completed as expected.');

################################################################################

sub service_control {
  my ($t, $port, $file) = @_;
  my $server = HttpServer->new($port, $t->testdir() . '/' . $file)
    or die "Can't create test server socket: $!\n";

  $server->on('POST', '/v1/services/endpoints-grpc-test.cloudendpointsapis.com:check', <<'EOF');
HTTP/1.1 200 OK
Connection: close

EOF

  $server->on('POST', '/v1/services/endpoints-grpc-test.cloudendpointsapis.com:report', <<'EOF');
HTTP/1.1 200 OK
Connection: close

EOF

  $server->run();
}

################################################################################
