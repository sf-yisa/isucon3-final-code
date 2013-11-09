#!/usr/bin/env perl
use strict;
use warnings;

use File::Basename;
use File::Temp qw/ tempfile /;
use Path::Tiny;
use POSIX qw/ floor /;
use Time::HiRes qw/ usleep /;
use Log::Minimal;

use constant {
    ICON_S   => 32,
    ICON_M   => 64,
    ICON_L   => 128,
    IMAGE_S  => 128,
    IMAGE_M  => 256,
    IMAGE_L  => undef,
};

my $root_dir  = File::Basename::dirname(__FILE__);
my $image_dir = path($root_dir)->child('data', 'image-new', 'raw');
$image_dir->parent->child('s')->mkpath;
$image_dir->parent->child('m')->mkpath;
$image_dir->parent->child('l')->mkpath;

while (1) {
    for my $image ($image_dir->children) {
        next if $image->basename eq '.gitignore';
        infof($image);
        # IMAGE_S
        {
            my $file = crop_square($image, 'jpg');
            my $data = convert($file, 'jpg', IMAGE_S, IMAGE_S);
            unlink $file;
            $image_dir->parent->child('s', $image->basename)->spew($data);
        }
        # IMAGE_M
        {
            my $file = crop_square($image, 'jpg');
            my $data = convert($file, 'jpg', IMAGE_M, IMAGE_M);
            unlink $file;
            $image_dir->parent->child('m', $image->basename)->spew($data);
        }
        # IMAGE_L
        {
            # 加工
            $image->move($image_dir->parent->child('l', $image->basename));
        }
        $image->remove;
    }

    # 100ms wait loop
    usleep(100_000);
}


# copied from Isucon3Final::Web

sub convert {
    # my $self = shift;
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
    # my $self = shift;
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
