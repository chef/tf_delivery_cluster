# Generate builder_key
resource "null_resource" "generate_builder_key" {
  provisioner "local-exec" {
    command = "ssh-keygen -t rsa -N '' -b 2048 -f .chef/builder_key -y"
  }
}

# Template to render encrypted_data_bag_secret
resource "template_file" "encrypted_data_bag_secret" {
  depends_on = ["null_resource.generate_builder_key"]
  template = "${builder_key}"
  vars {
    builder_key = "${file(".chef/builder_key")}"
  }
  provisioner "local-exec" {
    command = "echo '${base64encode("${template_file.encrypted_data_bag_secret.rendered}")}' > .chef/encrypted_data_bag_secret"
  }
}

# Create the data bag to store our builder keys
resource "chef_data_bag" "keys" {
  name = "keys"
}

# TODO: How to create encrypted_items?
# resource "chef_data_bag_item" "delivery_builder_keys" {
#     data_bag_name = "keys"
#     content_json = <<EOT
# {
#   "builder_key":  "${file(".chef/encrypted_data_bag_secret")}",
#   "delivery_pem": "${file(".chef/delivery.pem")}"
# }
# EOT
# }

# Setup chef-delivery
resource "aws_instance" "chef-delivery" {
  ami = "${var.ami}"
  count = "${var.count}"
  instance_type = "${var.instance_type}"
  subnet_id = "${var.subnet_id}"
  vpc_security_group_ids = ["${var.security_groups_ids}"]
  key_name = "${var.key_name}"
  tags {
    Name = "${format("chef-delivery-%02d", count.index + 1)}"
  }
  root_block_device = {
    delete_on_termination = true
  }
  connection {
    user = "${var.user}"
    key_fle = "${var.private_key_path}"
  }
  depends_on = ["null_resource.generate_builder_key", "template_file.encrypted_data_bag_secret"]

  # For now there is no way to delete the node from the chef-server
  # and also there is no way to customize your `destroy` actions
  # https://github.com/hashicorp/terraform/issues/649
  #
  # Workaround: Force-delete the node before hand
  provisioner "local-exec" {
    command = "knife node delete ${format("chef-delivery-%02d", count.index + 1)} -y | echo 'ugly'"
  }

  # Copies all files needed by Delivery
  provisioner "file" {
    source = ".chef"
    destination = "/tmp"
  }

  # Configure license and files
  provisioner "remote-exec" {
    inline = [
      "sudo service iptables stop",
      "sudo chkconfig iptables off",
      "sudo mkdir -p /var/opt/delivery/license",
      "sudo mkdir -p /etc/delivery",
      "sudo mkdir -p /etc/chef",
      "sudo chown root:root -R /tmp/.chef",
      "sudo mv /tmp/.chef/delivery.license /var/opt/delivery/license",
      "sudo chmod 644 /var/opt/delivery/license/delivery.license",
      "sudo mv /tmp/.chef/* /etc/delivery/.",
      "sudo mv /etc/delivery/trusted_certs /etc/chef/."
    ]
  }

  provisioner "chef"  {
    attributes {
      "delivery-cluster" {
        "delivery" {
          "chef_server" = "${var.chef-server-url}"
          "fqdn" = "${self.public_ip}"
        }
      }
    }
    # environment = "_default"
    run_list = ["delivery-cluster::delivery"]
    node_name = "${format("chef-delivery-%02d", count.index + 1)}"
    secret_key = "${template_file.encrypted_data_bag_secret.rendered}"
    server_url = "${var.chef-server-url}"
    validation_client_name = "terraform-validator"
    validation_key = "${file(".chef/terraform-validator.pem")}"
  }

  # Create Enterprise
  provisioner "remote-exec" {
    inline = [
      "sudo delivery-ctl create-enterprise ${var.enterprise} --ssh-pub-key-file=/etc/delivery/builder_key.pub > /tmp/${var.enterprise}.creds",
    ]
  }

  # TODO: How terraform can download files? If it doesn't then we may have to triangle the files
  #       that is (perhaps) upload the files somewhere or create a data bag and store them there.
  #
  # Workaround: Use scp to download the creds file
  provisioner "local-exec" {
    command  = "scp -oStrictHostKeyChecking=no -i ${var.private_key_path} ${var.user}@${self.public_ip}:/tmp/${var.enterprise}.creds .chef/${var.enterprise}.creds"
  }
}

# Template to render delivery_builder_keys item
resource "template_file" "delivery_builder_keys" {
  depends_on = ["null_resource.generate_builder_key", "template_file.encrypted_data_bag_secret"]
  template = "${file("chef-delivery/templates/delivery_builder_keys.tpl")}"
  vars {
    builder_key = "${replace(file(".chef/builder_key"), "/\n/", "\\\\n")}"
    delivery_pem = "${replace(file(".chef/delivery.pem"), "/\n/", "\\\\n")}"
  }
  provisioner "local-exec" {
    command = "echo '${template_file.delivery_builder_keys.rendered}' > .chef/delivery_builder_keys.json"
  }
  # Fetch Chef Delivery Certificate
  provisioner "local-exec" {
    command = "knife ssl fetch https://${aws_instance.chef-delivery.public_ip}"
  }
  # Upload cookbooks to the Chef Server
  provisioner "local-exec" {
    command = "knife data bag from file keys .chef/delivery_builder_keys.json --encrypt"
  }
}
