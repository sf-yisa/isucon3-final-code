package Isucon3Final::Web;

use strict;
use warnings;
use utf8;
use Kossy;
use Digest::SHA qw/ sha256_hex /;
use DBIx::Sunny;
use JSON;
use JSON::Types;
use File::Temp qw/ tempfile /;
use POSIX qw/ floor /;
use File::Copy;
use Data::UUID;
use HTTP::Date;
use Path::Tiny;
use Furl;
use Cache::Memory::Simple;
use Log::Minimal;
use Imager;

our $TIMEOUT  = 30;
our $INTERVAL = 2;
our $UUID     = Data::UUID->new;


use constant {
    ICON_S   => 32,
    ICON_M   => 64,
    ICON_L   => 128,
    IMAGE_S  => 128,
    IMAGE_M  => 256,
    IMAGE_L  => undef,
};

sub convert_imager {
    my $self = shift;
    my ($src, $size) = @_;
    my ($suffix) = ($src =~ /\.(jpg|png)$/);
    my $img = Imager->new(file => $src)
        or die Imager->errstr;
    my $h = $img->getheight();
    my $w = $img->getwidth();
    my $shorter = ($h > $w ? $w : $h);
    my $offset = floor(abs($h - $w) / 2);
    my $cropped;
    if ($h > $w) {
        $cropped = $img->crop(top => $offset, left => 0, width => $shorter, height => $shorter);
    } else {
        $cropped = $img->crop(top => 0, left => $offset, width => $shorter, height => $shorter);
    }
    my $resized = $cropped->scale(xpixels => $size, ypixels => $size);

    my ($fh, $filename) = tempfile();
    my $newfile = "$filename.$suffix";
    $resized->write(file => $newfile, type => ($suffix eq "jpg" ? "jpeg" : "png"))
        or die "failed to write file:" . $resized->errstr;
    open my $newfh, "<", $newfile or die $!;
    read $newfh, my $data, -s $newfile;
    close $newfh;
    unlink $newfile;
    unlink $filename;
    $data;
}

sub convert {
    my $self = shift;
    my ($orig, $ext, $w, $h) = @_;
    my ($fh, $filename) = tempfile();
    my $newfile = "$filename.$ext";
    system("convert", "-geometry", "${w}x${h}", $orig, $newfile);
    open my $newfh, "<", $newfile or die $!;
    read $newfh, my $data, -s $newfile;
    close $newfh;
    unlink $newfile;
    unlink $filename;
    $data;
}

sub crop_square {
    my $self = shift;
    my ($orig, $ext) = @_;
    my $identity = `identify $orig`;
    my (undef, undef, $size) = split / +/, $identity;
    my ($w, $h) = split /x/, $size;
    my ($crop_x, $crop_y, $pixels);
    if ( $w > $h ) {
        $pixels = $h;
        $crop_x = floor(($w - $pixels) / 2);
        $crop_y = 0;
    }
    elsif ( $w < $h ) {
        $pixels = $w;
        $crop_x = 0;
        $crop_y = floor(($h - $pixels) / 2);
    }
    else {
        $pixels = $w;
        $crop_x = 0;
        $crop_y = 0;
    }
    my ($fh, $filename) = tempfile();
    system("convert", "-crop", "${pixels}x${pixels}+${crop_x}+${crop_y}", $orig, "$filename.$ext");
    unlink $filename;
    return "$filename.$ext";
}

sub load_config {
    my $self = shift;
    $self->{_config} ||= do {
        my $env = $ENV{ISUCON_ENV} || 'local';
        open(my $fh, '<', $self->root_dir . "/../config/${env}.json") or die $!;
        my $json = do { local $/; <$fh> };
        close($fh);
        decode_json($json);
    };
}

sub dbh {
    my ($self) = @_;
    $self->{_dbh} ||= do {
        my $dbconf = $self->load_config->{database};
        my @dsn = $dbconf->{dsn}
                ? @{ $dbconf->{dsn} }
                : (
                    "dbi:mysql:database=${$dbconf}{dbname};host=${$dbconf}{host};port=${$dbconf}{port}",
                    $dbconf->{username},
                    $dbconf->{password},
                );
        DBIx::Sunny->connect(
            @dsn, {
                RaiseError           => 1,
                PrintError           => 0,
                AutoInactiveDestroy  => 1,
                mysql_enable_utf8    => 1,
                mysql_auto_reconnect => 1,
            }
        );
    };
}

filter 'require_user' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;
        if (! $c->stash->{user}) {
            $c->halt(400);
        }
        $app->($self, $c);
    };
};

filter 'get_user' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;
        my $api_key = $c->req->headers->header("X-API-Key")
                   || $c->req->cookies->{api_key}
        ;
        my $user = $self->dbh->select_row(
            'SELECT * FROM users WHERE api_key=?',
            $api_key,
        );
        $c->stash->{user} = $user;
        $app->($self, $c);
    };
};

filter 'uri_for' => sub {
    my ($app) = @_;
    sub {
        my ($self, $c) = @_;
        $c->stash->{uri_base} = $c->req->uri_for('/');
        $c->stash->{uri_base} =~ s!/$!!;
        $app->($self, $c);
    };
};

get '/' => sub {
    my ( $self, $c )  = @_;
    open my $fh, "<", "./public/index.html";
    my $html = do { local $/; <$fh> };
    $c->res->body($html);
};

post '/signup' => [qw/uri_for/] => sub {
    my ( $self, $c ) = @_;
    my $name = $c->req->param("name");
    if ( $name !~ /\A[0-9a-zA-Z_]{2,16}\z/ ) {
        $c->halt(400);
    }
    my $api_key = sha256_hex( $UUID->create );
    $self->dbh->query(
        'INSERT INTO users (name, api_key, icon) VALUES (?, ?, ?)',
        $name, $api_key, 'default',
    );
    my $id = $self->dbh->last_insert_id;
    my $user = $self->dbh->select_row(
        'SELECT * FROM users WHERE id=?', $id,
    );
    $c->render_json({
        id      => number $user->{id},
        name    => string $user->{name},
        icon    => string $c->stash->{uri_base} .'/'. $user->{icon},
        api_key => string $user->{api_key},
    });
};

get '/me' => [qw/ get_user require_user uri_for/] => sub {
    my ( $self, $c ) = @_;
    my $user = $c->stash->{user};
    $c->render_json({
        id   => number $user->{id},
        name => string $user->{name},
        icon => string $c->stash->{uri_base} ."/icon/" . $user->{icon},
    });
};

get '/icon/:icon' => sub {
    my ( $self, $c ) = @_;
    my $icon = $c->args->{icon};
    my $size = $c->req->param("size") || "s";
    my $dir  = $self->load_config->{data_dir};
    my $w = $size eq "s" ? ICON_S
          : $size eq "m" ? ICON_M
          : $size eq "l" ? ICON_L
          :                ICON_S;
    my $h = $w;

    # convert済みのデータがあればそれを返す
    my $data;
    my $res = Furl->new->get('http://isu251/icon/' . $size . '/' . "${icon}.png");
    if ($res->is_success) {
        $data = $res->content;
    } else {
        if ( ! -e "$dir/icon/${icon}.png" ) {
            $c->halt(404);
        }
        $data = $self->convert("$dir/icon/${icon}.png", "png", $w, $h);
    }
    $c->res->content_type("image/png");
    $c->res->header("Cache-Control", "max-age=86400");
    $c->res->header("Last-Modified", HTTP::Date::time2str);
    $c->res->content( $data );
    $c->res;
};

post '/icon' => [qw/ get_user require_user uri_for/] => sub {
    my ( $self, $c ) = @_;
    my $user   = $c->stash->{user};
    my $upload = $c->req->uploads->{image};
    if (!$upload) {
        $c->halt(400);
    }
    if ( $upload->content_type !~ /^image\/(jpe?g|png)$/ ) {
        $c->halt(400);
    }
    my $file = $self->crop_square($upload->path, "png");
    my $icon = sha256_hex( $UUID->create );
    my $dir  = $self->load_config->{data_dir};
    File::Copy::move($file, "$dir/icon/$icon.png")
        or $c->halt(500);

    for my $size ( qw/s m l/ ) {
        my $w = $size eq "s" ? ICON_S
              : $size eq "m" ? ICON_M
              : $size eq "l" ? ICON_L
                    :                ICON_S;
        my $h = $w;
        my $data = $self->convert("$dir/icon/$icon.png", "png", $w, $h);
        my $res = Furl->new->put('http://isu251/icon/'.$size.'/'. $icon .'.png', [], $data);
    }

    $self->dbh->query(
        'UPDATE users SET icon=? WHERE id=?',
        $icon, $user->{id},
    );
    $c->render_json({
        icon => string $c->stash->{uri_base} ."/icon/" . $icon,
    });
};

post '/entry' => [qw/ get_user require_user uri_for /] => sub {
    my ($self, $c) = @_;
    my $user   = $c->stash->{user};
    my $upload = $c->req->uploads->{image};
    if (!$upload) {
        $c->halt(400);
    }
    my $content_type = $upload->content_type;
    if ($content_type !~ /^image\/jpe?g/) {
        $c->halt(400);
    }
    my $image_id = sha256_hex( $UUID->create );
    my $dir = $self->load_config->{data_dir};
    # IMAGE_S
    {
        my $file = $self->crop_square($upload->path, 'jpg');
        my $data = $self->convert($file, 'jpg', IMAGE_S, IMAGE_S);
        unlink $file;
        my $res = Furl->new->put($self->load_config->{image_storage} . "/image/S/${image_id}.jpg", [], $data);
        infof('S size image %s', $res->is_success ? 'OK' : 'NG');
    }
    # IMAGE_M
    {
        my $file = $self->crop_square($upload->path, 'jpg');
        my $data = $self->convert($file, 'jpg', IMAGE_M, IMAGE_M);
        unlink $file;
        my $res = Furl->new->put($self->load_config->{image_storage} . "/image/M/${image_id}.jpg", [], $data);
        infof('M size image %s', $res->is_success ? 'OK' : 'NG');
    }
    # IMAGE_L
    {
        # TODO 加工？
        open my $in, '<', $upload->path or $c->halt(500);
        my $data = do { local $/; <$in> };
        close $in;
        my $res = Furl->new->put($self->load_config->{image_storage} . "/image/L/${image_id}.jpg", [], $data);
        infof('L size image %s', $res->is_success ? 'OK' : 'NG');
    }
    File::Copy::move($upload->path, "$dir/image/$image_id.jpg")
        or $c->halt(500);

    my $publish_level = $c->req->param("publish_level");
    $self->dbh->query(
        'INSERT INTO entries (user, image, publish_level, created_at) VALUES (?, ?, ?, now())',
        $user->{id}, $image_id, $publish_level,
    );
    my $id = $self->dbh->last_insert_id;
    my $entry = $self->dbh->select_row(
        'SELECT * FROM entries WHERE id=?', $id,
    );
    $c->render_json({
        id            => number $entry->{id},
        image         => string $c->stash->{uri_base} . "/image/" . $entry->{image},
        publish_level => number $entry->{publish_level},
        user => {
            id   => number $user->{id},
            name => string $user->{name},
            icon => string $c->stash->{uri_base} . "/icon/" . $user->{icon},
        },
    });
};

post '/entry/:id' => [qw/ get_user require_user /] => sub {
    my ( $self, $c ) = @_;
    my $user  = $c->stash->{user};
    my $id    = $c->args->{id};
    my $dir   = $self->load_config->{data_dir};
    my $entry = $self->dbh->select_row("SELECT * FROM entries WHERE id=?", $id);
    if ( !$entry ) {
        $c->halt(404);
    }
    if ( $entry->{user} != $user->{id} || $c->req->param("__method") ne "DELETE" )
    {
        $c->halt(400);
    }
    $self->dbh->query("DELETE FROM entries WHERE id=?", $id);
    $c->render_json({
        ok => JSON::true,
    });
};


get '/image/:image' => [qw/ get_user /] => sub {
    my ( $self, $c ) = @_;
    my $user  = $c->stash->{user};
    my $image = $c->args->{image};
    my $size  = $c->req->param("size") || "l";
    my $dir   = $self->load_config->{data_dir};
    my $entry = $self->dbh->select_row(
        "SELECT * FROM entries WHERE image=?", $image,
    );
    if ( !$entry ) {
        $c->halt(404);
    }
    if ( $entry->{publish_level} == 0 ) {
        if ( $user && $entry->{user} == $user->{id} ) {
            # publish_level==0 はentryの所有者しか見えない
            # ok
        }
        else {
            $c->halt(404);
        }
    }
    elsif ( $entry->{publish_level} == 1 ) {
        # publish_level==1 はentryの所有者かfollowerしか見えない
        if ( $entry->{user} == $user->{id} ) {
            # ok
        } else {
            my $follow = $self->dbh->select_row(
                "SELECT * FROM follow_map WHERE user=? AND target=?",
                $user->{id}, $entry->{user},
            );
            $c->halt(404) if !$follow;
        }
    }

    my $w = $size eq "s" ? IMAGE_S
          : $size eq "m" ? IMAGE_M
          : $size eq "l" ? IMAGE_L
          :                IMAGE_L;
    my $h = $w;
    my $data;

    # convert済みのデータがあればそれを返す
    my $res = Furl->new->get($self->load_config->{image_storage} . '/image/' . uc($size) . '/' . "${image}.jpg");
    if ($res->is_success) {
        $data = $res->content;
    } else {
        # 無ければ初期実装通りにconvertして返す
        if ($w) {
            $data = $self->convert_imager("$dir/image/${image}.jpg", ($h > $w ? $w : $h));
        } else {
            open my $in, "<", "$dir/image/${image}.jpg" or $c->halt(500);
            $data = do { local $/; <$in> };
        }
    }
    $c->res->content_type("image/jpeg");
    $c->res->content( $data );
    $c->res;
};

sub get_following {
    my ($self, $c) = @_;
    my $user = $c->stash->{user};
    my $following = $self->dbh->select_all(
        "SELECT users.* FROM follow_map JOIN users ON (follow_map.target=users.id) WHERE follow_map.user = ?",
        $user->{id},
    );
    $c->res->header("Cache-Control" => "no-cache");
    $c->render_json({
        users => [
            map {
                my $u = $_;
                +{
                    id   => number $u->{id},
                    name => string $u->{name},
                    icon => string $c->stash->{uri_base} . "/icon/" . $u->{icon},
                };
            } @$following
        ],
    });
};

get '/follow' => [qw/ get_user require_user uri_for /] => \&get_following;

post '/follow' => [qw/ get_user require_user uri_for /] => sub {
    my ($self, $c) = @_;
    my $user = $c->stash->{user};
    for my $target ( $c->req->param("target") ) {
        next if $target == $user->{id};
        $self->dbh->query(
            "INSERT IGNORE INTO follow_map (user, target, created_at) VALUES (?, ?, now())",
            $user->{id}, $target,
        );
    }
    get_following($self, $c);
};

post '/unfollow' => [qw/ get_user require_user uri_for /] => sub {
    my ($self, $c) = @_;
    my $user = $c->stash->{user};
    for my $target ( $c->req->param("target") ) {
        next if $target == $user->{id};
        $self->dbh->query(
            "DELETE FROM follow_map WHERE user=? AND target=?",
            $user->{id}, $target,
        );
    }
    get_following($self, $c);
};

get '/timeline' => [qw/ get_user require_user uri_for /] => sub {
    my ($self, $c) = @_;
    my $user = $c->stash->{user};
    my $latest_entry = $c->req->param("latest_entry");
    my ($sql, @params);
    my $sort;
    if ($latest_entry) {
        $sql = 'SELECT entries.*,users.id as user_id,users.name as user_name, users.icon as user_icon FROM entries FORCE INDEX(PRIMARY) JOIN users ON (entries.user = users.id) WHERE (entries.user=? OR entries.publish_level=2 OR (entries.publish_level=1 AND entries.user IN (SELECT target FROM follow_map WHERE user=?))) AND entries.id > ? ORDER BY id LIMIT 30';
        @params = ($user->{id}, $user->{id}, $latest_entry);
        $sort = 1;
    }
    else {
        $sql = 'SELECT entries.*,users.id as user_id,users.name as user_name, users.icon as user_icon FROM entries FORCE INDEX(PRIMARY) JOIN users ON (entries.user = users.id) WHERE entries.user=? OR entries.publish_level=2 OR (entries.publish_level=1 AND entries.user IN (SELECT target FROM follow_map WHERE user=?)) ORDER BY entries.id DESC LIMIT 30';
        @params = ($user->{id}, $user->{id});
    }

    my $entries = $self->dbh->select_all($sql, @params);
    my @entries = @$entries;
    if ( $sort ) {
        @entries = reverse @entries;
    }
    $latest_entry = $entries[0]->{id} if @entries;

    $c->res->header("Cache-Control" => "no-cache");
    $c->render_json({
        latest_entry => number $latest_entry,
        entries => [
            map {
                my $entry = $_;
                +{
                    id         => number $entry->{id},
                    image      => string $c->stash->{uri_base} ."/image/" . $entry->{image},
                    publish_level => number $entry->{publish_level},
                    user => {
                        id   => number $entry->{user_id},
                        name => string $entry->{user_name},
                        icon => string $c->stash->{uri_base} ."/icon/" . $entry->{user_icon},
                    },
                }
            } @entries
        ]
    });
};


1;
