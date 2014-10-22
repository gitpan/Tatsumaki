# just a clone of Plack::Server::AnyEvent for now
# removed AIO support and ContentLength middleware
package Tatsumaki::Server;
use strict;
use warnings;
use 5.008_001;

use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Socket;
use Carp ();
use Plack::Util;
use HTTP::Status;
use Plack::HTTPParser qw(parse_http_request);
use IO::Handle;
use Errno ();
use Scalar::Util ();
use Socket qw(IPPROTO_TCP TCP_NODELAY);

sub new {
    my($class, %args) = @_;

    my $self = bless {}, $class;
    $self->{host} = delete $args{host} || undef;
    $self->{port} = delete $args{port} || undef;

    $self;
}

sub register_service {
    my($self, $app) = @_;

    my $guard = tcp_server $self->{host}, $self->{port}, sub {

        my ( $sock, $peer_host, $peer_port ) = @_;

        if ( !$sock ) {
            return;
        }
        setsockopt($sock, IPPROTO_TCP, TCP_NODELAY, 1)
            or die "setsockopt(TCP_NODELAY) failed:$!";

        my $env = {
            SERVER_PORT       => $self->{prepared_port},
            SERVER_NAME       => $self->{prepared_host},
            SCRIPT_NAME       => '',
            'psgi.version'    => [ 1, 0 ],
            'psgi.errors'     => *STDERR,
            'psgi.url_scheme' => 'http',
            'psgi.nonblocking'  => Plack::Util::TRUE,
            'psgi.streaming'    => Plack::Util::TRUE,
            'psgi.run_once'     => Plack::Util::FALSE,
            'psgi.multithread'  => Plack::Util::FALSE,
            'psgi.multiprocess' => Plack::Util::FALSE,
            REMOTE_ADDR       => $peer_host,
        };

        # Note: broken pipe in test is maked by Test::TCP.
        my $handle;
        $handle = AnyEvent::Handle->new(
            fh       => $sock,
            timeout  => 3,
            on_eof   => sub { undef $handle; undef $env; },
            on_error => sub { undef $handle; undef $env; warn $! if $! != Errno::EPIPE },
            on_timeout => sub { undef $handle; undef $env; },
        );

        my $parse_header;
        $parse_header = sub {
            my ( $handle, $chunk ) = @_;
            my $reqlen = parse_http_request($chunk . "\015\012", $env);
            if ($reqlen < 0) {
                $self->_write_headers($handle, 400, [ 'Content-Type' => 'text/plain' ]);
                $handle->push_write("400 Bad Request");
            } else {
                my $response_handler = $self->_response_handler($handle, $sock);
                if ($env->{CONTENT_LENGTH} && $env->{REQUEST_METHOD} =~ /^(?:POST|PUT)$/) {
                    # Slurp content
                    $handle->push_read(
                        chunk => $env->{CONTENT_LENGTH}, sub {
                            my ($handle, $data) = @_;
                            open my $input, "<", \$data;
                            $env->{'psgi.input'} = $input;
                            $response_handler->($app, $env);
                        }
                    );
                } else {
                    open my $input, "<", \"";
                    $env->{'psgi.input'} = $input;
                    $response_handler->($app, $env);
                }
            }
          };

        $handle->unshift_read( line => qr{(?<![^\012])\015?\012}, $parse_header );
        return;
      }, sub {
          my ( $fh, $host, $port ) = @_;
          $self->{prepared_host} = $host;
          $self->{prepared_port} = $port;
          warn "Accepting requests at http://$host:$port/\n";
          return 0;
      };
    $self->{listen_guard} = $guard;
}

sub _write_headers {
    my($self, $handle, $status, $headers) = @_;

    my $hdr;
    $hdr .= "HTTP/1.0 $status @{[ HTTP::Status::status_message($status) ]}\015\012";
    while (my ($k, $v) = splice(@$headers, 0, 2)) {
        $hdr .= "$k: $v\015\012";
    }
    $hdr .= "\015\012";

    $handle->push_write($hdr);
}

sub _response_handler {
    my($self, $handle, $sock) = @_;

    Scalar::Util::weaken($sock);

    return sub {
        my($app, $env) = @_;
        my $res = Plack::Util::run_app $app, $env;

        # PSGI standard
        if (ref $res eq 'ARRAY') {
            $self->_write_response($res, $handle, $sock);
        } elsif (ref $res eq 'CODE') {
            $res->(sub {
                my $res = shift;
                $self->_write_response($res, $handle, $sock);
            });
        } else {
            Carp::carp("Unknown response type: $res");
        }
    };
}

sub _write_response {
    my($self, $res, $handle, $sock) = @_;

    $self->_write_headers($handle, $res->[0], $res->[1]);

    my $body = $res->[2];
    my $disconnect_cb = sub { $handle->on_drain(sub { $handle->destroy }) };

    if (!defined $body) {
        return Plack::Util::inline_object
            write => sub { $handle->push_write($_) for @_ },
            close => $disconnect_cb;
    } elsif ( ref $body eq 'GLOB' ) {
        no warnings 'recursion';
        $handle->on_drain(sub {
            my $read = $body->read(my $buf, 4096);
            $handle->push_write($buf);
            if ($read == 0) {
                $body->close;
                $handle->on_drain;
                $handle->destroy;
            }
        });
    } else {
        Plack::Util::foreach( $body, sub { $handle->push_write($_[0]) } );
        $disconnect_cb->();
    }
}

sub run {
    my $self = shift;
    $self->register_service(@_);
    AnyEvent->condvar->recv;
}

1;
__END__
